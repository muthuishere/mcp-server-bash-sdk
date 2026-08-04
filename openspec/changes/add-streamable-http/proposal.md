## Why

[ADR-0001](../../../docs/adr/0001-stdio-only-transport.md) rejected Streamable HTTP
because it meant sessions, SSE resumability, a long-lived GET stream and server-initiated
requests. The `2026-07-28` revision deleted all of them, leaving *POST a JSON-RPC message,
get a JSON object back*. Statelessness turned an HTTP binding from a state-management
problem into a request-mapping one, and the core already treats every message as a pure
function — so the transport is ~250 lines rather than a rewrite.

The SDK also has exactly one example server, built on canned movie data. That is enough to
show the syntax and not enough to show the pattern working against something real.

## What Changes

- Add `mcpserver_http.sh`: the Streamable HTTP binding, mapping HTTP onto the *same*
  `process_request` the stdio binding uses, so the two cannot drift.
- Enforce the revision's header↔body contract — `MCP-Protocol-Version`, `Mcp-Method`, and
  `Mcp-Name` (including `=?base64?…?=` decoding) must be present and match the body, else
  `400` with `-32020 HeaderMismatch`.
- Map protocol errors onto the prescribed HTTP statuses: `-32022`/`-32020`/`-32700` → 400,
  `-32601` → 404, notifications → `202` with no body, everything else → 200.
- Answer legacy traffic as the spec prescribes: `405` for GET/DELETE, `Mcp-Session-Id` and
  `Last-Event-ID` ignored rather than rejected.
- Validate `Origin` against an allowlist (`403` otherwise) and bind `127.0.0.1` by default.
- Select the listener backend at startup — `socat` (forks per connection) if present,
  otherwise `ncat`, otherwise a BSD-`nc` re-arm loop — and log which one is in use.
- Add `examples/gitserver.sh`: a read-only git server (`git_status`, `git_log`,
  `git_show`) that runs over **both** transports from one file, plus
  `examples/README.md` walking through building a server from scratch.
- Add `test_http_transport.sh`: 19 tests driving a real server with `curl`.

Explicitly **not** in scope: SSE response mode (the spec permits `application/json` for
every response), `subscriptions/listen`, TLS, and authentication.

## Capabilities

### New Capabilities
- `http-transport`: the Streamable HTTP binding — endpoint and method rules, header↔body
  validation, status-code mapping, Origin enforcement, legacy-traffic handling, and
  listener-backend selection.

### Modified Capabilities
None. `mcp-protocol-core` and `tool-dispatch` are unchanged by design — the HTTP layer
adds no protocol semantics, which is the property the shared `process_request` guarantees.

## Impact

- New: `mcpserver_http.sh`, `test_http_transport.sh`, `examples/gitserver.sh`,
  `examples/assets/gitserver_{config,tools}.json`, `examples/README.md`.
- `docs/adr/0001-stdio-only-transport.md` — marked superseded in scope by
  [ADR-0006](../../../docs/adr/0006-add-streamable-http.md); its stdio analysis stands.
- `readme.md`, `CLAUDE.md`, `VERSIONS.md` — a second transport and a second example change
  the product surface.
- **Portability constraint discovered by
  [spike 02](../../../docs/spikes/spike-02-http-listener.md) and now binding on this
  file**: no `read -N` and no `declare -A`, because neither exists in bash 3.2 — which is
  what `#!/bin/bash` resolves to on macOS.
- The `nc` backend serves one connection at a time; the suite runs in ~2 s once the
  server shuts down cleanly.
