## Context

`mcpserver_core.sh` is ~270 lines implementing MCP `2024-11-05` over stdio: an
`initialize` handler that echoes a config file, `tools/list` that echoes a tools file,
and `tools/call` that dispatches to `tool_<name>` shell functions. Messages are parsed
with six `jq` forks and responses are assembled by string concatenation.

Target is `2026-07-28`, which is stateless: no handshake, per-request `_meta`, mandatory
`server/discover`, `resultType` on every result, `ttlMs`/`cacheScope` on list results.
The five ADRs in `docs/adr/` fix the boundaries; this document is how the code gets there.

## Goals / Non-Goals

**Goals:**
- A stdio server that a `2026-07-28` client can drive without a shim.
- Wire output that validates against the official published schema, proven by a test.
- The `tool_<name>` author contract survives unchanged in shape (`echo` + `return 0|1`).
- One `jq` fork on the parse path; `jq -n --arg` on every build path.

**Non-Goals:**
- Streamable HTTP (ADR-0001), resources, prompts, completions, pagination.
- MRTR `InputRequiredResult`s — no tool here needs sampling or elicitation yet.
- The tasks extension, `subscriptions/listen` change streams (ADR-0001 records why a
  single-threaded read loop cannot serve them honestly).
- Backward compatibility with pre-`2026-07-28` clients (ADR-0002).

## Decisions

**One parse function, `parse_message`.** A single `jq -j` emits `jsonrpc`, `id`,
`method`, `protocolVersion`, `toolName`, `arguments` joined by ASCII Unit Separator
(0x1f), read into locals with `IFS=$'\x1f' read -r`. Not `@tsv`: it escapes backslashes,
which would double-escape the `arguments` blob. 0x1f is safe because JSON requires
control characters to be escaped, so it cannot appear literally in the text. An absent
`id` is the empty string, which is how a notification is told apart from a request whose
id is literally `null` — the one distinction the dispatcher needs.

**One build function per envelope.** `create_response` and `create_error_response` take
values, never pre-built JSON strings, and construct with `jq -n --arg/--argjson`. This
kills the injection class the old `"{\"message\": \"$msg\"}"` had.

**Version gate at dispatch, not per handler.** `process_request` checks
`_meta.io.modelcontextprotocol/protocolVersion` once, before the method `case`, and
short-circuits with `-32022`. `server/discover` is exempt — it is the method a client
uses to *learn* the supported version, so gating it would deadlock negotiation.

**Config files become the discovery document.** `MCP_CONFIG_FILE` stops being an
`initialize` result and becomes a `DiscoverResult` body: `supportedVersions`,
`capabilities`, `instructions`, `ttlMs`, `cacheScope`. `serverInfo` moves out of the
result body into result `_meta`, where `2026-07-28` puts it — so the core reads
`serverInfo` from the config and injects it into every response's `_meta`.

**`tools/list` decorates rather than echoes.** The tools file stays a plain
`{"tools":[…]}` so authors are not asked to hand-write cache fields; the core adds
`resultType`, `ttlMs`, `cacheScope`, and sorts nothing (file order is the deterministic
order, which is the author's to control).

**Tool output keeps its newlines.** Drop `tr '\n' ' '`; `jq -R -s` alone already escapes
newlines as `\n` inside the JSON string, which satisfies "no embedded newlines on the
wire" without destroying the content.

**Errors split by origin** (ADR-0005): tool exits non-zero → `isError: true` result;
tool not found → `-32602`; method not found → `-32601`; bad envelope → `-32600`; bad
version → `-32022`.

## Risks / Trade-offs

- **No client can talk to this today.** Shipping ahead of client adoption is the whole
  point of ADR-0002, but it means the demo is exercised by our own test harness rather
  than by an editor. Mitigated by the conformance test being schema-driven, so "it works"
  is a checkable claim rather than a hopeful one.
- **Positional decoding is brittle** — adding an extracted field means editing the
  filter and the `read` together. Contained to one function, commented with field order.
- **Breaking the tool contract's error semantics** silently changes behaviour for anyone
  who built on `return 1` expecting a protocol error. Recorded as BREAKING in
  `VERSIONS.md`; the new behaviour is what the spec asks for and what tool authors
  actually want.
- **Vendored 180 KB schema** in a deliberately tiny repo (ADR-0003). Data, not code, and
  never on the server path.
- **The spec is two weeks old at time of writing.** Errata are likely. The vendored
  schema turns any future correction into a failing test rather than a silent
  incompatibility.
