# Spike 01 — Is stdio good enough to be the only transport?

**Run it:** `./docs/spikes/spike-01-stdio-viability.sh` (numbers below from an M-series
Mac, bash 5.3, jq 1.7, `N=200`; re-run to refresh).

**Answer: yes — and the 2026-07-28 revision makes it a better bet than it was.**

## Measurements

| Experiment | Result |
| --- | --- |
| 200 requests through one long-lived server over a pipe | 200 responses, **0 lost / merged**, ~48 ms per request, ~21 req/s |
| Cost of a single `jq` fork+parse | ~2.6–3.0 ms |
| 4 separate `jq` calls vs 1 combined call, same message | 11.2 ms vs 3.0 ms → **3.8× available on the parse path** |
| Single-line payload of 64 KB / 512 KB / 4 MB | read back **intact** at every size |
| Multi-line tool output → protocol stream | flattened to one JSON string, no newline escapes into the wire |
| stdin EOF | server exits `rc=0`; every stdout line parses as JSON; stderr clean |

## What the numbers actually say

1. **Bash is not the bottleneck; `jq` forks are.** The read loop costs nothing
   measurable. The current core spends 6 `jq` invocations parsing one request and 2
   more building the response — at ~2.6 ms each that *is* the 48 ms. Collapsing the
   parse into one `jq` call per message is the single highest-value optimization, and
   experiment 3 shows it is worth ~3.8× on that path.

2. **21 req/s is the right number for the workload.** A tool call lives inside an LLM
   turn costing 1–10 s, so ~48 ms of protocol overhead is a low single-digit percent.
   The honest caveat: this would be indefensible for a shared multi-tenant HTTP
   service — which is precisely what the stdio binding never is. One client, one
   subprocess, no concurrency requirement.

3. **`read -r` has no line-length ceiling.** 4 MB on one line round-trips intact. The
   limit is memory, not a buffer. (`ARG_MAX` bites if you pass such a payload through
   `argv` — that is a shell limit, not a stdio one, and the spike now builds large
   lines through a file to avoid conflating the two.)

4. **The no-embedded-newline rule is upheld, but destructively.** `tr '\n' ' ' | jq -R -s`
   satisfies the spec at the cost of shredding formatting in multi-line tool output.
   `jq -R -s` on its own already escapes newlines as `\n` and would preserve it — the
   `tr` is unnecessary damage. Worth fixing during the rewrite.

## Why 2026-07-28 makes stdio *easier*, not harder

The parts of the old protocol that were awkward in a single-threaded shell loop are
the exact parts the new revision deleted:

- **No sessions, no `initialize` handshake** — nothing to keep in memory between
  messages. The server becomes a pure function of one line in → one line out, which is
  the natural shape of a bash read loop.
- **No SSE resumability, no `Last-Event-ID`** — never applied to stdio anyway, and now
  gone from the protocol entirely.
- **Servers never initiate JSON-RPC requests** (MRTR replaces sampling / elicitation /
  roots callbacks). The single shared stdout channel no longer has to multiplex
  server-initiated request/response pairs against in-flight tool work — the hardest
  thing to do correctly without real concurrency.
- **`ping` and `logging/setLevel` removed**; logging deprecated in favour of stderr,
  which is where a shell script wants to log anyway.

The one genuinely new obligation with teeth is `subscriptions/listen`: a long-lived
response stream. On stdio it degrades gracefully — the notifications are just extra
lines on stdout tagged with a subscription ID — but a single-threaded `read` loop
cannot emit them while blocked on the next request. That is a real limitation to
document, not to hide.

## Outcome after the rewrite

Re-run against the 2026-07-28 core (same machine, same `N`, requests now carrying the
per-request `_meta` the revision requires):

| | Old core, 2024-11-05 | New core, 2026-07-28 |
| --- | --- | --- |
| jq forks per request | 9 (6 parse + 2 build + 1 tool) | 4 (1 parse + 1 build + 1 envelope + 1 tool) |
| Per request | ~48 ms | **~34 ms** |
| Throughput | ~21 req/s | **~30 req/s** |

~1.4× end-to-end, not the 3.8× of experiment 3 — that figure was always parse-path only,
and the response side now does strictly more work (`resultType`, `_meta` serverInfo, cache
hints) on a richer message. The remaining forks are irreducible without leaving `jq`.

## Decisions this spike feeds

- [ADR-0001 — stdio is the only transport](../adr/0001-stdio-only-transport.md)
- [ADR-0004 — one `jq` call per message](../adr/0004-single-jq-parse.md)
