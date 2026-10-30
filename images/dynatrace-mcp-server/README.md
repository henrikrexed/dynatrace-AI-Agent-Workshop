# dynatrace-mcp-server image

Purpose-built container for the kagent **Dynatrace MCP** tool server. It bakes
the pinned [`@dynatrace-oss/dynatrace-mcp-server`](https://www.npmjs.com/package/@dynatrace-oss/dynatrace-mcp-server)
npm package into the image so the stdio server starts instantly.

## Why this exists (ISI-6938)

The manifest originally ran `npx -y @dynatrace-oss/dynatrace-mcp-server` as the
pod command. `npx -y` resolves and **downloads the package from npm at process
start**. On a fresh / slow Codespace that cold start could exceed the kagent MCP
client's `initialize` timeout, producing:

```
failed to init MCP session: calling "initialize": sending "initialize":
rejected by transport: Post "http://dynatrace-mcp.kagent:3000/mcp":
context deadline exceeded (Client.Timeout exceeded while awaiting headers)
```

Pre-installing the package (`npm i -g` at **build** time) removes the runtime
fetch — the `mcp-server-dynatrace` binary is on `PATH` and the server answers
`initialize` within a second or two. Same pattern as the GitHub MCP server,
which already ships as a pre-built image.

## Versions

Single-source-of-truth pins live in [`cluster/versions.env`](../../cluster/versions.env):

| Variable                   | Meaning                                            |
| -------------------------- | -------------------------------------------------- |
| `DYNATRACE_MCP_PACKAGE`    | pinned npm package (`@scope/name@version`) baked in |
| `DYNATRACE_MCP_NODE_IMAGE` | base image the build runs on (`node:22-slim`)      |
| `DYNATRACE_MCP_IMAGE`      | published runtime image the manifest references    |

Bump `DYNATRACE_MCP_PACKAGE`, let
[`.github/workflows/build-dynatrace-mcp-image.yml`](../../.github/workflows/build-dynatrace-mcp-image.yml)
publish the matching image tag, then bump `DYNATRACE_MCP_IMAGE` to match.

## Build locally

```bash
docker build \
  --build-arg NODE_IMAGE=node:22-slim \
  --build-arg DYNATRACE_MCP_VERSION=2.1.2 \
  -t ghcr.io/henrikrexed/dynatrace-mcp-server:2.1.2 \
  images/dynatrace-mcp-server
```

The stdio server reads/writes nothing sensitive to the image; the platform token
(`DT_PLATFORM_TOKEN`) and environment URL (`DT_ENVIRONMENT`) are injected into the
pod at apply time by `agents/install-agents.sh`.
