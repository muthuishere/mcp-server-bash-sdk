## Context

The SDK ships a stdio binding over `mcpserver_core.sh`, whose `process_request` is already
a pure function of one message. `2026-07-28` removed sessions, the GET stream, SSE
resumability and server-initiated requests, so an HTTP binding no longer needs state of its
own — it needs to map HTTP onto that existing function and enforce the transport's own
rules (headers, statuses, Origin).

[Spike 02](../../../docs/spikes/spike-02-http-listener.md) established the two real
constraints: there is no dependable listener on a stock machine (BSD `nc` only, no `-e`,
no `--keep-open`), and `read -N` / `declare -A` do not exist in bash 3.2, which is what
`#!/bin/bash` gets on macOS.

## Goals / Non-Goals

**Goals:**
- One MCP endpoint over POST that a `2026-07-28` client can drive.
- Zero protocol logic in the transport: identical results over stdio and HTTP by
  construction.
- Enforce header↔body agreement, which is a security control, not a formality.
- Run on a stock macOS box with no extra packages.
- A worked example that exercises both transports from a single file.

**Non-Goals:**
- SSE response mode, `subscriptions/listen`, progress streaming.
- TLS, authentication, multi-tenancy, concurrency beyond what `socat` gives for free.
- Being a general-purpose HTTP server. Anything past the MCP endpoint returns 404.

## Decisions

**The transport calls `process_request` and nothing else.** `handle_http_request` parses
HTTP, validates the transport's rules, hands the body to the core, and maps the returned
JSON-RPC message onto a status code. No method dispatch, no result construction. This is
why `mcp-protocol-core` needs no delta spec: the HTTP path cannot behave differently
because there is no second implementation to disagree.

**Status mapping is driven by the error code in the body**, read once after
`process_request` returns: `-32022`/`-32020`/`-32700`/`-32600` → 400, `-32601` → 404,
everything else → 200. A tool that failed still returns 200 — `isError` is a result, not a
transport fault (ADR-0005).

**Header validation happens before dispatch and short-circuits.** Checking version, then
method, then name means the error message always names the first thing that is wrong,
rather than a generic mismatch. `Mcp-Name` is required only for `tools/call`,
`resources/read` and `prompts/get`, matching the spec's table, and is decoded from the
`=?base64?…?=` sentinel before comparison.

**A version mismatch between header and body is `-32020`, not `-32022`.** They are
different failures: one means the request is internally inconsistent (the case an
intermediary could exploit), the other means the server cannot speak what was asked for.
Collapsing them would hide the security-relevant one.

**Origin absent is allowed; Origin present must be allowlisted.** Browsers always send it,
non-browser clients typically do not, and the attack being prevented — DNS rebinding — is
a browser attack. Rejecting requests with no Origin would break `curl` and every CLI client
while preventing nothing.

**Backend chosen at startup, and disclosed.** `socat` → `ncat` → `nc`, logged and printed
to stderr. The `nc` path prints an explicit warning that it serves one connection at a
time. Hiding the degradation would make the transport feel unreliable instead of limited.

**Bash 3.2 rules, enforced by review:** `head -c "$len"` for the body, a flat set of
variables for the header table. Both were chosen because the alternatives fail *silently*
on the default macOS shell, which is the worst possible failure mode.

**The example runs both transports from one file.** `gitserver.sh` dispatches on `--http`,
so the two bindings are demonstrated as a deployment choice rather than as two different
programs — which is exactly the relationship they have.

## Risks / Trade-offs

- **One connection at a time on `nc`**, with a window between connections where the port is
  refused. The HTTP test suite retries around it. Real clients will occasionally see a
  connection refused; `socat` removes this entirely.
- **No SSE means no progress notifications.** Acceptable because every method this SDK
  implements answers immediately, but it forecloses long-running tools until SSE lands.
- **`Origin` plus loopback binding is the entire security model.** No auth, no TLS.
  Anything beyond localhost needs a reverse proxy, and the readme says so rather than
  leaving it implied.
- **Re-exec per connection under `socat`** means the server script is sourced afresh for
  every request, so per-process caching (like `MCP_SERVER_INFO`) buys nothing on that
  backend. Correct either way, just slower than it looks.
- **`head -c` may buffer ahead** on some implementations. Harmless here because the
  connection is closed after one request/response pair, but it would matter if keep-alive
  were ever added.
