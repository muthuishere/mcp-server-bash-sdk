# ADR-0005 — Tool failures are `isError` results, not JSON-RPC errors

- **Status:** Accepted
- **Date:** 2026-08-04

## Context

The old core mapped a tool function returning non-zero onto a JSON-RPC `-32603`
(Internal error) response. The spec says the opposite, explicitly:

> Any errors that originate from the tool SHOULD be reported inside the result object,
> with `isError` set to true, *not* as an MCP protocol-level error response. Otherwise,
> the LLM would not be able to see that an error occurred and self-correct.
> However, any errors in *finding* the tool … should be reported as an MCP error response.
> — `CallToolResult`, schema 2026-07-28

This is not pedantry. A protocol-level error is a transport failure to a client: it is
surfaced to the user, not to the model. `tool_book_ticket` rejecting `numTickets: "two"`
is exactly the case where the model should see the message and retry with `2`.

The existing `tool_validate_age` shows the workaround the old design forced: it returns
`0` with an explanatory string for a *failed* validation, because returning `1` would
have hidden the reason from the model. That is the contract leaking.

## Decision

Split the two error classes by origin:

| Situation | Response |
| --- | --- |
| `tool_<name>` returns non-zero | `CallToolResult` with `isError: true`, the tool's output as the text content, JSON-RPC **success** |
| No `tool_<name>` function exists | JSON-RPC error `-32602` (Invalid params) — the tool name is a bad parameter |
| Unknown method | JSON-RPC error `-32601` |
| Malformed / non-2.0 envelope | JSON-RPC error `-32600` |
| Unsupported protocol version in `_meta` | JSON-RPC error `-32022` with `data.requested` / `data.supported` |

The `tool_*` author contract is unchanged — `echo` + `return 0|1` — but `return 1` now
means "tell the model this went wrong", which is what authors already assumed.

## Consequences

**Good**

- Models can self-correct on validation failures instead of the user seeing a red error.
- `tool_validate_age`'s workaround disappears: a failed age check can honestly `return 1`.
- Aligns the SDK with how every other MCP SDK behaves, so tools port cleanly.

**Bad / accepted**

- Behaviour change for existing servers built on this SDK: a `return 1` that used to
  produce a JSON-RPC error now produces a successful response carrying `isError`.
  Recorded in `VERSIONS.md` as breaking.
- "Tool not found" moves from `-32601` to `-32602`, matching the spec's own realignment
  of resource-not-found from `-32002` to `-32602`. Existing tests asserting `-32601` for
  a missing tool must be updated — deliberately, not silenced.
