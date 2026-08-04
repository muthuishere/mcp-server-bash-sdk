# ADR-0004 — One `jq` invocation per message on the parse path

- **Status:** Accepted
- **Date:** 2026-08-04
- **Evidence:** [Spike 01, experiments 2 and 3](../spikes/spike-01-findings.md)

## Context

Spike 01 measured ~48 ms per request end-to-end and traced it: a `jq` fork costs
~2.6 ms, and the old core spent **six** of them parsing one request (`jsonrpc`, `id`,
`method`, `params`, `params.name`, `params.arguments`) plus two building the response.
Bash's own read loop was not measurable in comparison.

Experiment 3 compared four separate `jq` calls against one combined call extracting the
same four fields: **11.2 ms vs 3.0 ms — 3.8× on the parse path.**

The 2026-07-28 shape makes this worse if ignored: every request now also carries
`_meta` protocol version, client capabilities, client info and log level, which naively
adds four more forks per message.

## Decision

**Parse each incoming message with exactly one `jq` invocation** that emits all needed
fields joined by ASCII Unit Separator (`0x1f`), read into shell variables with a single
`IFS=$'\x1f' read`.

`@tsv` was the obvious choice and is wrong here: it escapes backslashes, which would
corrupt the `arguments` blob (`{"a":"b\\c"}` comes back double-escaped). `join("\u001f")`
does not transform its inputs. It is safe because 0x1f cannot appear literally inside JSON
text — the spec requires control characters to be escaped, and `tojson` emits them as
`\u001f`. Raw newlines in extracted *scalars* would still break the `read`, so the filter
squashes them to spaces; the `arguments` blob is unaffected because `tojson` has already
escaped its newlines as the two characters `\` and `n`.

The same rule applies on the way out: build each response with one `jq -n` call using
`--arg`/`--argjson`, rather than assembling JSON by string concatenation.

## Outcome

Measured after implementation: jq forks per request dropped from 9 to 4, and end-to-end
cost from ~48 ms to ~34 ms (~21 → ~30 req/s). That is **1.4×, not 3.8×** — the larger
figure was parse-path only, and the response side now does more work than before
(`resultType`, `_meta` serverInfo, cache hints). The decision still pays; the headline
number was optimistic.

## Consequences

**Good**

- 1.4× end-to-end, on a message shape that got richer rather than simpler.
- `jq -n --arg` construction removes an entire class of bug the old core had: building
  JSON with `"{\"code\": $code, \"message\": \"$errorMessage\"}"` breaks the moment a
  message contains a quote or backslash. Quoting becomes `jq`'s problem, correctly.

**Bad / accepted**

- One long `jq` program instead of several obvious one-liners: denser to read. Mitigated
  by keeping it in a single named function with the field order commented.
- Positional decoding is order-sensitive — adding a field means updating the
  filter and the `read` in lockstep. Contained to one function.

## Alternatives considered

- **Keep per-field `jq` calls for readability** — rejected: it is the single dominant
  cost in the only performance number this SDK has.
- **Replace `jq` with a pure-bash JSON parser** — rejected: it would be more code than
  the SDK, slower than one `jq` fork for realistic payloads, and wrong in the corners
  (unicode escapes, number formats) that `jq` gets right.
