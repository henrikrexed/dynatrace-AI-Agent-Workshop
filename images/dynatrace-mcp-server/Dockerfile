# syntax=docker/dockerfile:1

# ── Purpose-built Dynatrace MCP tool-server image (ISI-6938) ─────────────────
# The kagent Dynatrace MCPServer used to run `npx -y @dynatrace-oss/...` at pod
# start, which fetched the package from npm on every cold start. On a fresh or
# slow Codespace that fetch could exceed the MCP client's `initialize` timeout
# ("context deadline exceeded ... while awaiting headers"), so tool discovery
# failed. Baking the pinned package into the image makes startup instant.
#
# Built + pushed (multi-arch) by .github/workflows/build-dynatrace-mcp-image.yml
# to ghcr.io/henrikrexed/dynatrace-mcp-server:<version>. The version and base
# image come from cluster/versions.env (DYNATRACE_MCP_PACKAGE /
# DYNATRACE_MCP_NODE_IMAGE) — bump there to roll the image.

ARG NODE_IMAGE=node:22-slim
FROM ${NODE_IMAGE}

# Pinned Dynatrace MCP server package version (the part after the final @ in
# DYNATRACE_MCP_PACKAGE). Overridden by the build workflow from versions.env.
ARG DYNATRACE_MCP_VERSION=2.1.2

LABEL org.opencontainers.image.title="dynatrace-mcp-server" \
      org.opencontainers.image.description="Dynatrace MCP server (@dynatrace-oss/dynatrace-mcp-server) pre-installed for kagent — instant stdio startup, no runtime npx fetch." \
      org.opencontainers.image.source="https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="IsItObservable"

ENV HOME=/tmp \
    npm_config_cache=/tmp/.npm \
    NODE_ENV=production

# Install the pinned package GLOBALLY at build time (as root) so the
# `mcp-server-dynatrace` binary is on PATH and runtime startup needs no network.
# `command -v` verifies the binary exists WITHOUT executing it — the server is a
# stdio process and would block the build if actually launched.
RUN npm install -g "@dynatrace-oss/dynatrace-mcp-server@${DYNATRACE_MCP_VERSION}" \
 && npm cache clean --force \
 && command -v mcp-server-dynatrace

# Drop to the unprivileged user the base image ships (uid 1000).
USER node

# Default transport is stdio (kagent bridges stdio<->HTTP via agentgateway).
# kagent's MCPServer.deployment.cmd/args override this ENTRYPOINT at apply time.
ENTRYPOINT ["mcp-server-dynatrace"]
