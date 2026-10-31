#!/usr/bin/env python3
"""Map Phoenix span-dataframe rows to the input/output/context the judges need.

Why this exists (ISI-6951 / ISI-6955)
-------------------------------------
`--from-phoenix` pulls spans with ``client.spans.get_spans_dataframe()``, which
flattens every span attribute into an ``attributes.<key>`` column. The judges
need three columns — ``input``, ``output``, ``context`` — so we have to find the
prompt and response under whatever keys the exporter used.

The catch: our agents export **OTel GenAI semantic-convention** spans through
the collector-gateway, so the content lands under ``gen_ai.*`` keys — either the
indexed ``gen_ai.prompt.N.content`` / ``gen_ai.completion.N.content`` form, the
newer structured ``gen_ai.input.messages`` / ``gen_ai.output.messages`` form, or
GenAI log-events on the span. The original code only looked for OpenInference
keys (``input.value`` / ``output.value``), so it matched **zero** spans and
dead-ended with "Found spans but none carried LLM input/output attributes."

This module covers both conventions in one place so `run_phoenix_eval.py` and
`run_diagnosis_eval.py` map spans identically. If a new exporter uses yet another
key, add it to the ordered lists below — that is the single edit point.
"""
from __future__ import annotations

import json

import pandas as pd

# Single-valued attribute columns, highest-confidence first. The first one that
# carries a non-empty value wins.
INPUT_KEYS = (
    "attributes.input.value",             # OpenInference (llm / chain spans)
    "attributes.gen_ai.input.messages",   # OTel GenAI semconv (structured list)
    "attributes.gen_ai.prompt",           # bare prompt string (some SDKs)
    "attributes.llm.input_messages",      # OpenInference (legacy flat key)
)
OUTPUT_KEYS = (
    "attributes.output.value",            # OpenInference
    "attributes.gen_ai.output.messages",  # OTel GenAI semconv (structured list)
    "attributes.gen_ai.completion",       # bare completion string
    "attributes.llm.output_messages",     # OpenInference (legacy flat key)
)
CONTEXT_KEYS = (
    "attributes.retrieval.documents",     # OpenInference RAG context
    "attributes.gen_ai.context",
)

# Indexed attribute families — ``<prefix>N.content`` columns, concatenated in
# numeric order. This is how Traceloop/OpenLLMetry-style SDKs (and our gateway's
# normalised output) emit multi-message prompts/responses.
INPUT_INDEXED = ("attributes.gen_ai.prompt.",)
OUTPUT_INDEXED = ("attributes.gen_ai.completion.",)

# GenAI log-events carry the message content on the span's ``events`` column when
# the exporter uses event-based capture instead of attributes.
INPUT_EVENT_NAMES = ("gen_ai.user.message", "gen_ai.system.message",
                     "gen_ai.tool.message")
OUTPUT_EVENT_NAMES = ("gen_ai.assistant.message", "gen_ai.choice")
_EVENT_CONTENT_KEYS = ("content", "gen_ai.event.content", "message", "body")


def _nonempty(v) -> bool:
    """True for a scalar/str/list/dict that actually carries text."""
    if v is None:
        return False
    try:
        if pd.isna(v):  # scalars and NaN; raises/returns array for list-likes
            return False
    except (ValueError, TypeError):
        pass  # list / dict / ndarray — not NaN, keep going
    return str(v).strip() not in ("", "nan", "None", "[]", "{}")


def _coerce_text(v) -> str:
    """Structured messages arrive as a list/dict (new semconv) or JSON string.

    The judge grades text, so a stable JSON dump is fine either way.
    """
    if isinstance(v, (list, dict)):
        try:
            return json.dumps(v, ensure_ascii=False)
        except (TypeError, ValueError):
            return str(v)
    return str(v)


def _pick(row, keys) -> str:
    for k in keys:
        if k in row and _nonempty(row[k]):
            return _coerce_text(row[k])
    return ""


def _index_of(col: str, prefix: str) -> int:
    head = col[len(prefix):].split(".", 1)[0]
    return int(head) if head.isdigit() else 10 ** 9


def _pick_indexed(row, prefixes) -> str:
    index = getattr(row, "index", [])
    for prefix in prefixes:
        cols = [c for c in index
                if c.startswith(prefix) and c.endswith(".content")]
        cols.sort(key=lambda c: _index_of(c, prefix))
        parts = [_coerce_text(row[c]) for c in cols if _nonempty(row[c])]
        if parts:
            return "\n".join(parts)
    return ""


def _from_events(row, names) -> str:
    try:
        events = row.get("events")
    except (AttributeError, KeyError):
        return ""
    if not isinstance(events, (list, tuple)):
        return ""
    parts = []
    for ev in events:
        if not isinstance(ev, dict) or ev.get("name") not in names:
            continue
        attrs = ev.get("attributes")
        if not isinstance(attrs, dict):
            continue
        for key in _EVENT_CONTENT_KEYS:
            if key in attrs and _nonempty(attrs[key]):
                parts.append(_coerce_text(attrs[key]))
                break
    return "\n".join(parts)


def extract_input(row) -> str:
    return (_pick(row, INPUT_KEYS)
            or _pick_indexed(row, INPUT_INDEXED)
            or _from_events(row, INPUT_EVENT_NAMES))


def extract_output(row) -> str:
    return (_pick(row, OUTPUT_KEYS)
            or _pick_indexed(row, OUTPUT_INDEXED)
            or _from_events(row, OUTPUT_EVENT_NAMES))


def extract_context(row) -> str:
    return _pick(row, CONTEXT_KEYS)


def attribute_columns(df) -> list[str]:
    """The ``attributes.*`` columns actually present — for diagnostics when
    nothing maps, so the attendee can see what keys their spans really use."""
    cols = getattr(df, "columns", [])
    return sorted(c for c in cols if str(c).startswith("attributes."))
