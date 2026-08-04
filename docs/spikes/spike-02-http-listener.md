# Spike 02 — Can Bash serve Streamable HTTP?

**Run it:** `./docs/spikes/spike-02-http-listener.sh` (numbers from an M-series Mac,
bash 5.3 in PATH / bash 3.2 at `/bin/bash`, BSD `nc`, no `socat`).

**Answer: yes — the MCP part is easy now. Being a TCP server is the hard part.**

[ADR-0001](../adr/0001-stdio-only-transport.md) rejected HTTP because of sessions, SSE
resumability, the GET stream and server-initiated requests. 2026-07-28 deleted every one
of those. What is left is *POST a message, get a JSON object back* — so this spike asked
whether the remaining obstacles are real.

## Findings

### 1. You cannot assume a listener exists

| Tool | On this machine | Behaviour |
| --- | --- | --- |
| `socat` | **absent** | forks per connection — the only backend that handles overlapping clients |
| `ncat` | **absent** | has `--keep-open` / `--sh-exec` |
| `nc` | present (BSD/macOS) | no `-e`, no `--keep-open` → needs a FIFO re-arm loop |

A stock macOS box has only BSD `nc`. So the transport must ship a `nc` fallback, and that
fallback serves **one connection at a time**, with a window between connections where the
port is refused. Measured ~13 ms per sequential request; 3/3 and 5/5 sequential requests
served cleanly, but a second simultaneous client waits for the listener to be re-armed.

### 2. The obvious way to read the body is broken on the bash people actually have

```
bash 3.2.57 + read -N : BROKEN (read 0 bytes, expected 92)
bash 3.2.57 + head -c : OK
bash 5.3.9  + read -N : OK
bash 5.3.9  + head -c : OK
```

`read -N` — read exactly N bytes — **does not exist in bash 3.2**, which is what macOS
ships as `/bin/bash` and therefore what every `#!/bin/bash` script on a stock Mac runs
under. It fails silently: no error, an empty body, a server that returns parse errors for
every request. `head -c "$len"` works on both and stops exactly at the body boundary.

The same trap applies to `declare -A` (bash 4+), so the header table cannot be an
associative array. Both constraints are now rules in `mcpserver_http.sh`.

This is the single most useful thing the spike found, and no amount of reading the MCP
spec would have surfaced it.

### 3. HTTP framing itself is fine

Request line, headers to the blank line, then `Content-Length` bytes — all
straightforward. The body must *not* be read with plain `read -r`: it has no trailing
newline, so `read` returns non-zero and, depending on how you check, you drop the message.

## Verdict

Ship it, scoped honestly: a **local, single-client endpoint**. Bind `127.0.0.1`, validate
`Origin`, prefer `socat` when present, and say plainly in the readme that the `nc` path
serves one connection at a time. It is not a production web server, and documenting it as
one would be the actual mistake.

Deferred: SSE response mode. The spec permits `application/json` for every response, and
SSE reintroduces exactly the framing and keep-alive complexity that made ADR-0001 say no.
Revisit when a client genuinely needs `notifications/progress`.

## Decisions this spike feeds

- [ADR-0006 — Add the Streamable HTTP transport, as a local endpoint](../adr/0006-add-streamable-http.md)
