## Why

The SDK speaks MCP `2024-11-05`, four revisions behind the current `2026-07-28` spec — a
revision that deleted exactly the machinery a shell script handles worst (sessions, the
`initialize` handshake, server-initiated requests) and made statelessness the default.
[Spike 01](../../../docs/spikes/spike-01-findings.md) confirms the stdio binding is
comfortably viable in Bash (~48 ms/request, no message loss, 4 MB lines intact), so the
gap is protocol currency, not capability.

## What Changes

- **BREAKING** — Remove the `initialize` method and the `notifications/initialized` sink.
  Protocol version and client capabilities now arrive on every request in
  `params._meta`.
- Add `server/discover` (a spec **MUST**) advertising `supportedVersions`,
  `capabilities`, `instructions`, and identity.
- **BREAKING** — Every result gains a required `resultType: "complete"`. `tools/list`
  additionally gains required `ttlMs` and `cacheScope` (`CacheableResult`).
- Every result carries `_meta["io.modelcontextprotocol/serverInfo"]`.
- Reject requests whose `_meta` protocol version is not `2026-07-28` with
  `UnsupportedProtocolVersionError` (`-32022`, `data.requested` + `data.supported`).
- **BREAKING** — A tool returning non-zero now yields a successful `CallToolResult` with
  `isError: true` instead of a JSON-RPC `-32603`; a missing tool moves from `-32601` to
  `-32602`. See [ADR-0005](../../../docs/adr/0005-tool-errors-are-results.md).
- Preserve multi-line tool output instead of flattening it with `tr '\n' ' '`.
- Support `notifications/cancelled` (the stdio cancellation signal) as a no-response sink.
- Parse each message with a single `jq` invocation and build every response with
  `jq -n --arg`, ending string-concatenated JSON. ~3.8× on the parse path.
- Vendor `spec/schema-2026-07-28.json` and add a schema-validating conformance test.

Explicitly **not** in scope: the Streamable HTTP transport
([ADR-0001](../../../docs/adr/0001-stdio-only-transport.md)), resources, prompts, MRTR
`InputRequiredResult`s, and the tasks extension.

## Capabilities

### New Capabilities
- `mcp-protocol-core`: the JSON-RPC 2.0 + MCP 2026-07-28 message layer — dispatch,
  per-request version negotiation, result envelopes, error codes, `server/discover`.
- `stdio-transport`: the stdio binding — newline framing, stdout purity, stderr logging,
  EOF shutdown, cancellation.
- `tool-dispatch`: the `tool_<name>` shell-function contract — discovery, name
  validation, argument passing, success/`isError` mapping.

### Modified Capabilities
None — this is the first OpenSpec change in the repo, so all three capabilities are new.

## Impact

- `mcpserver_core.sh` — rewritten around the new envelope; `handle_initialize` removed,
  `handle_discover` added.
- `assets/movieserver_config.json` — reshaped into a `DiscoverResult` body
  (`protocolVersion` → `supportedVersions`, plus `ttlMs`/`cacheScope`).
- `assets/movieserver_tools.json` — gains the cache fields; tools ordered deterministically.
- `moviemcpserver.sh` — `tool_validate_age` can now honestly `return 1` on a failed check.
- `test_mcpserver_core.sh` — the two pre-existing failures fixed; legacy `initialize`
  tests replaced with `server/discover` tests.
- New: `test_conformance.sh`, `spec/schema-2026-07-28.json`.
- `readme.md`, `CLAUDE.md`, `VERSIONS.md` — the tool-author contract and protocol version
  changed, so all three must be updated in lockstep.
- **Clients older than `2026-07-28` will be rejected.** Deliberate; see
  [ADR-0002](../../../docs/adr/0002-target-2026-07-28-only.md).
