# ADR-0001 — stdio is the only transport

- **Status:** Superseded in scope by [ADR-0006](0006-add-streamable-http.md) — Streamable HTTP was added once the 2026-07-28 revision removed sessions, SSE resumability and the GET stream. Everything below about stdio remains in force.
- **Date:** 2026-08-04
- **Evidence:** [Spike 01 — Is stdio good enough?](../spikes/spike-01-findings.md)

## Context

MCP defines two standard transport bindings: stdio (newline-delimited JSON-RPC over a
client-launched subprocess) and Streamable HTTP (POST per message, SSE or JSON reply).
This SDK is written in Bash, so the question is not "which is better" but "which one can
a shell script actually honour to the letter."

Spike 01 measured the stdio path end-to-end rather than guessing:

- 200 requests through one long-lived server: **200 responses, zero lost or merged**,
  ~48 ms per request, ~21 req/s single-threaded.
- Single-line payloads of 64 KB, 512 KB and **4 MB** read back intact — `read -r` has no
  line-length ceiling.
- Clean `rc=0` exit on stdin EOF; every stdout line parsed as JSON; stderr stayed clean.
- The cost is `jq` forks (~2.6 ms each), not bash.

Streamable HTTP, by contrast, would require in Bash: a socket listener (no `socat` on a
default macOS box; BSD `nc` cannot fork per connection), correct SSE framing with
keep-alive comments, `Origin` validation, and byte-exact `Mcp-Method` / `Mcp-Name` /
`Mcp-Param-*` header↔body validation including the `=?base64?…?=` sentinel decoding —
each a spec MUST whose violation is a `400` or a DNS-rebinding hole.

## Decision

**Implement the stdio binding only.** No HTTP endpoint, no SSE, no listener process.
A deployment that needs HTTP fronts this server with a real HTTP server (`mcp-proxy`,
a reverse proxy, an inetd-style wrapper) rather than growing one inside the shell.

## Consequences

**Good**

- Every spec MUST in scope is one a shell script can actually meet: newline framing, no
  embedded newlines, stdout purity, stderr for logging, exit on EOF.
- 2026-07-28 deleted the parts of the protocol that were awkward here anyway — sessions,
  the `initialize` handshake, SSE resumability, and server-initiated JSON-RPC requests
  (replaced by MRTR). The server becomes a pure function: one line in, one line out.
- One client per process means concurrency is not a requirement, so 21 req/s is a
  non-issue: the call sits inside an LLM turn already costing seconds.

**Bad / accepted**

- No remote or multi-tenant deployment without an external proxy.
- `subscriptions/listen` cannot be served faithfully: a single-threaded `read` loop
  cannot emit notifications while blocked awaiting the next request. We answer the
  request and acknowledge the subscription, but change notifications only flow if the
  server has something to say at the moment it is dispatching. Documented, not hidden.
- Throughput is unfixable by an order of magnitude without leaving Bash. Accepted; see
  [ADR-0004](0004-single-jq-parse.md) for the ~3.8× that *is* available.

## Alternatives considered

- **Streamable HTTP via `nc`/`socat`** — rejected: no dependable listener on a stock
  macOS/Linux box, and correct SSE plus header validation is more protocol surface than
  the entire rest of this SDK.
- **stdio + a thin HTTP shim in the repo** — rejected for now as scope; the shim would
  be a different language and defeat the "pure Bash" premise. External proxies already
  solve it.
