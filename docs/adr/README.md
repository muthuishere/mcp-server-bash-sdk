# Architecture Decision Records

Why this SDK is shaped the way it is. One decision per file, newest last.

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-stdio-only-transport.md) | stdio is the only transport | Superseded in scope by 0006 |
| [0002](0002-target-2026-07-28-only.md) | Target MCP 2026-07-28 exclusively — no `initialize`, no legacy era | Accepted |
| [0003](0003-schema-driven-conformance.md) | Conformance asserted against the vendored official schema | Accepted |
| [0004](0004-single-jq-parse.md) | One `jq` invocation per message on the parse path | Accepted |
| [0005](0005-tool-errors-are-results.md) | Tool failures are `isError` results, not JSON-RPC errors | Accepted |
| [0006](0006-add-streamable-http.md) | Add Streamable HTTP as a local endpoint — statelessness made it cheap | Accepted |
| [0007](0007-portability-is-tested.md) | Portability is verified in containers, not asserted — never put unbounded data on `argv` | Accepted |

Decisions are evidence-backed where evidence was cheap to get: see
[`docs/spikes/`](../spikes/) for the runnable experiments the numbers come from.
