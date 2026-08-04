# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Model Context Protocol server SDK in pure Bash, implementing MCP revision
**2026-07-28** over both standard transports. Three layers, split by file:

- `mcpserver_core.sh` — the protocol layer. JSON-RPC framing, method dispatch, per-request
  version negotiation, result envelopes, error codes. It defines functions only; sourcing
  it starts nothing. `run_mcp_server` is the stdio entry point.
- `mcpserver_http.sh` — the Streamable HTTP binding. Parses HTTP, enforces the header↔body
  contract, maps errors onto status codes, then calls **the same `process_request`**. It
  contains no protocol logic, which is what keeps the two transports from drifting.
- `moviemcpserver.sh`, `examples/gitserver.sh` — *implementations*. Set the config
  variables, source the core (and optionally the HTTP layer), define `tool_*` functions,
  dispatch on `--http`.

Users copy an implementation, not the core. `examples/README.md` is the walkthrough.

## Commands

```bash
./test_mcpserver_core.sh                        # 31 unit tests, one per spec scenario
./test_mcpserver_core.sh test_discover_shape    # a single test by function name
./test_conformance.sh                           # validate live output against the official schema
./test_http_transport.sh                        # 19 HTTP tests (drives a real server over curl)
./test_http_transport.sh test_bad_origin_is_403 # a single HTTP test
./docs/spikes/spike-01-stdio-viability.sh       # re-measure the stdio numbers
./docs/spikes/spike-02-http-listener.sh         # re-check listener/portability assumptions
./scripts/test-linux.sh all                     # run both suites on Debian, Alpine, Ubuntu (Docker)

# one-shot smoke test (note: every request MUST carry _meta protocolVersion)
echo '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' | ./moviemcpserver.sh
```

`jq` is the only hard dependency (plus `bc`, used by `tool_book_ticket`). `test_conformance.sh`
additionally needs Python with `jsonschema` and **skips cleanly** without it — point it at an
interpreter that has it with `MCP_CONFORMANCE_PYTHON=/path/to/python ./test_conformance.sh`.
No build step, no package manager, no linter.

## The contract between the two layers

Tool dispatch is by **shell function name**, not a registry: `handle_tools_call` looks up
`tool_<name>` with `type` and calls it with the arguments JSON as `$1`.

- A tool exists at runtime iff a `tool_<name>` function is in scope. `assets/*_tools.json`
  only controls what clients are *told* exists — the two can silently drift.
- Names are validated against `^[a-zA-Z0-9_]+$` before dispatch, so a call can never
  resolve to an arbitrary shell function.
- Success: `echo` the payload, `return 0`. Failure: `echo` the reason, `return 1` → a
  **successful** JSON-RPC response carrying `isError: true`, not a protocol error. This is
  deliberate ([ADR-0005](docs/adr/0005-tool-errors-are-results.md)): the model must see
  tool failures to self-correct. Only *finding* the tool failing is a protocol error.
- Tool output is stringified with `jq --arg`, so newlines survive as `\n` inside the JSON
  string. Content is always a single `content[0].type == "text"` block; structured content
  is not supported.

Configuration variables must be set **before** `source mcpserver_core.sh` — the core reads
them at source time via `${VAR:-default}`:

| Variable | Purpose | Core's default (does not exist in repo) |
| --- | --- | --- |
| `MCP_CONFIG_FILE` | the `server/discover` body + `serverInfo` | `assets/mcpserverconfig.json` |
| `MCP_TOOLS_LIST_FILE` | `{"tools":[…]}` | `assets/tools_list.json` |
| `MCP_LOG_FILE` | append-only log | `mcpserver.log` |
| `MCP_DEFAULT_TTL_MS` / `MCP_DEFAULT_CACHE_SCOPE` | cache hints when the config omits them | `60000` / `public` |

Unlike the old core, config files are no longer echoed back verbatim — `handle_discover`
and `handle_tools_list` *decorate* them with `resultType`, `ttlMs` and `cacheScope`, and
`create_response` injects `_meta` serverInfo into every result. A missing or malformed
config file yields `-32603` rather than a malformed result.

Logging is file-only by design: stdout is the protocol channel and any stray `echo` in a
tool corrupts the stream. Use `log LEVEL "msg"`; set `MCP_LOG_STDERR=1` to mirror to stderr.

## Protocol shape (2026-07-28)

MCP is now **stateless** — this is the thing to internalise before editing the core:

- **No `initialize`, no `notifications/initialized`.** They are gone from the protocol, not
  just unimplemented. Every request carries
  `params._meta["io.modelcontextprotocol/protocolVersion"]` and `…/clientCapabilities`.
- `process_request` gates on that version *once*, before the method `case`, answering a
  mismatch with `-32022` and `data: {requested, supported[]}`. **`server/discover` is
  exempt** — it is how a client learns which versions exist, so gating it would deadlock
  negotiation.
- Every result carries `resultType: "complete"` and `_meta` serverInfo. List results carry
  `ttlMs` + `cacheScope`.
- Notifications (no `id`) are never answered — not even to report that they were malformed.
- Error codes: `-32700` parse, `-32600` bad envelope / bad tool name, `-32601` unknown
  method, `-32602` unknown tool, `-32603` server-side failure, `-32022` unsupported version.
  `-32020..-32099` is reserved for the spec — do not invent codes there.

Not implemented, deliberately: SSE response mode, resources, prompts, MRTR
`InputRequiredResult`s, `subscriptions/listen` streams, the tasks extension, pagination.

## HTTP transport (`mcpserver_http.sh`)

Local endpoint only — loopback bind, `Origin` allowlist, no TLS, no auth (ADR-0006).

- POST only on one path. GET/DELETE → `405`; `Mcp-Session-Id` and `Last-Event-ID` are
  ignored, not rejected — they belong to superseded revisions.
- `MCP-Protocol-Version` and `Mcp-Method` are required on every request POST, `Mcp-Name`
  on `tools/call`/`resources/read`/`prompts/get`, and **each must match the body** or the
  answer is `400` + `-32020`. `Mcp-Name` may arrive as `=?base64?<b64>?=` and must be
  decoded before comparison. A version *header/body* mismatch is `-32020`, not `-32022`;
  they are different failures and collapsing them hides the security-relevant one.
- Status mapping: `-32022`/`-32020`/`-32700`/`-32600` → 400, `-32601` → 404, notification
  → 202 with no body, everything else → 200 (including a tool that returned `isError`).
- Backend is picked at startup: `socat` (forks) → `ncat` → BSD `nc` (one connection at a
  time, with a refusal window between connections — the HTTP tests retry around it). The
  netcat listen syntax is probed, not sniffed (`mcp_nc_listen_flag`).
- **The accept loop must stay backgrounded + `wait`ed on.** bash defers traps until the
  foreground command finishes, and `nc` blocks until a client connects — a foreground
  pipeline leaves `SIGTERM` pending forever and the server unkillable. `mcp_http_shutdown`
  reaps the pipeline's children, or `nc` outlives the server holding the port.

**Portability rules in this file** (spike 02; both fail *silently* on bash 3.2):
never use `read -N` (use `head -c "$len"`), never use `declare -A` (flat variables for the
header table).

## Portability — two traps pointing opposite ways

Both were found by running the suites on the other platform, not by review
([ADR-0007](docs/adr/0007-portability-is-tested.md), [spike 03](docs/spikes/spike-03-linux-portability.md)):

- **macOS is the old-bash platform.** `/bin/bash` is **3.2**: no `read -N`, no `declare -A`,
  no `;&` case fallthrough. Applies to `scripts/` too — the Linux harness itself tripped on
  `;&` on its first run.
- **Linux is the strict-kernel platform.** A single `argv` entry is capped at **128 KB**
  (`MAX_ARG_STRLEN`) regardless of total `ARG_MAX`; macOS has no such cap. **Never pass
  unbounded data through `argv`** — tool output and result objects go to `jq` on *stdin*
  (`create_response` reads its result from stdin; `--arg` is for short bounded values only).
  A 500 KB payload assertion in `scripts/test-linux.sh` is the regression test.

Platform-variant commands are resolved by *probing*, not by parsing version strings:
`mcp_nc_listen_flag` binds a scratch port to learn whether netcat wants `-l PORT` or
`-l -p PORT`; `base64 -d` falls back to `-D`. Nothing may depend on `bc` — it is absent from
slim images; `jq` does arithmetic.

## Editing conventions

- **Read `docs/adr/` before changing architecture.** Five ADRs cover transport, protocol
  revision, conformance strategy, the `jq` budget, and tool-error semantics — each records
  what was rejected and why.
- **`docs/spikes/` holds runnable evidence**, not prose. If you make a performance claim,
  re-run `spike-01-stdio-viability.sh` and update the numbers rather than asserting.
- **`openspec/changes/` is the change workflow** (`openspec validate <change>`,
  `openspec archive <change>`). Spec scenarios there map 1:1 onto tests in
  `test_mcpserver_core.sh` — add a scenario and a test together.
- `readme.md` is the product surface and contains a full copy-pasteable server template.
  Any change to the tool contract, config variable names, or the discovery payload must be
  mirrored there.
- Bump `VERSIONS.md` (Keep-a-Changelog style) for user-visible protocol or contract changes;
  mark breaking ones **BREAKING**.
- `spec/schema-2026-07-28.json` is vendored upstream bytes — refresh it deliberately when
  the revision moves, and let the conformance test tell you what broke.

## Performance notes

Measured, not assumed (see [spike 01 findings](docs/spikes/spike-01-findings.md)):
~34 ms/request, ~30 req/s, 4 `jq` forks per request. **`jq` forks are the entire cost** —
bash's read loop is not measurable next to them. Parse each message with one `jq` call and
build responses with `jq -n --arg` ([ADR-0004](docs/adr/0004-single-jq-parse.md)); never
assemble JSON by string concatenation, which is both slower and a quoting bug waiting to
happen.
