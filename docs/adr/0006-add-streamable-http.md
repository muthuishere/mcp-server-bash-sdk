# ADR-0006 — Add the Streamable HTTP transport, as a local endpoint

- **Status:** Accepted — supersedes the scope decision in [ADR-0001](0001-stdio-only-transport.md)
- **Date:** 2026-08-04
- **Evidence:** [Spike 02 — Can Bash serve Streamable HTTP?](../spikes/spike-02-http-listener.md)

## Context

ADR-0001 rejected Streamable HTTP because correct implementation meant sessions, SSE
framing with keep-alives, resumability via `Last-Event-ID`, and a long-lived GET stream —
more protocol surface than the rest of the SDK combined.

**That reasoning expired with the revision it was written against.** 2026-07-28 deleted
every one of those mechanisms: no `Mcp-Session-Id`, no GET stream, no resumability, no
server-initiated requests. What remains is *POST a JSON-RPC message, get a JSON object
back*. A stateless protocol makes an HTTP binding a request-mapping exercise, not a
state-management one — and the core already treats every message as a pure function.

Spike 02 measured what is actually hard, and it is not MCP:

- **No `socat` on a stock macOS box.** BSD `nc` has neither `-e` nor `--keep-open`, so the
  fallback is a FIFO accept loop serving one connection at a time, with a window between
  connections where the port is refused. ~13 ms per sequential request.
- **`read -N` does not exist in bash 3.2**, which is what `#!/bin/bash` resolves to on
  macOS. The obvious way to read exactly `Content-Length` bytes silently reads nothing.
  `head -c "$len"` works on 3.2 and 5.x and stops at the body boundary. `declare -A` is
  the same trap, so the header table cannot be an associative array.

## Decision

**Ship `mcpserver_http.sh` as a second transport over the same core**, and scope it
honestly as a **local, single-client endpoint** — not a production web server.

- `process_request` is shared verbatim. The HTTP layer only maps HTTP↔JSON-RPC; all
  protocol semantics stay in `mcpserver_core.sh`.
- Listener backend is chosen at startup: `socat` if present (forks per connection),
  otherwise a `nc` re-arm loop. The choice is logged, not hidden.
- Binds `127.0.0.1` by default and validates `Origin` (`403` on mismatch), per the spec's
  DNS-rebinding requirements.
- Enforces the header↔body contract the revision requires: `MCP-Protocol-Version`,
  `Mcp-Method`, and `Mcp-Name` must be present and must match the body, including
  `=?base64?…?=` decoding, rejecting with `400` and `-32020 HeaderMismatch`.
- Legacy traffic gets the spec's prescribed answers: `405` for GET/DELETE,
  `Mcp-Session-Id` and `Last-Event-ID` ignored.
- Body framing uses `head -c`; no `read -N`, no `declare -A` anywhere in the transport.

## Consequences

**Good**

- The SDK now covers both standard bindings, and the HTTP one is ~250 lines because the
  protocol did the hard part.
- Header↔body validation is a genuine security control (a proxy routing on headers while
  the server executes the body is the attack the spec's `-32020` exists to prevent), and
  it is testable.
- Reusing `process_request` means stdio and HTTP cannot drift in protocol behaviour — the
  conformance suite covers both by construction.

**Bad / accepted**

- **One connection at a time on the `nc` path**, with a refusal window between them.
  Fine for a local agent; unusable as a shared service. Documented in the readme's
  limitations rather than papered over.
- No SSE response mode, so no `notifications/progress` streaming and no
  `subscriptions/listen`. Both are optional for a server that answers immediately; a
  client that requires streaming will not be satisfied by this transport.
- No TLS and no auth. `127.0.0.1` binding plus `Origin` validation is the entire security
  model; exposing it beyond localhost requires a real reverse proxy in front.
- ADR-0001's *evidence* remains valid — this reverses its conclusion because the protocol
  changed underneath it, not because the original analysis was wrong.

## Alternatives considered

- **Keep stdio-only, tell users to run `mcp-proxy`** — still the right answer for remote
  or multi-client deployments, and the readme says so. But it makes the simplest local
  HTTP case require a Python dependency to do what is now ~250 lines of shell.
- **Require `socat`** — rejected: absent on stock macOS, so it would make the transport
  undeployable on the platform the SDK is most used on. It stays the preferred backend
  when present.
- **Implement SSE response mode too** — deferred. It is optional in the spec (a server
  MAY answer with `application/json`), and it reintroduces the framing and keep-alive
  complexity that made ADR-0001 say no. Revisit if a real client needs progress
  notifications.
