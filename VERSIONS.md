# Version History

## 0.4.1 (2026-08-05)

Makes "runs on Linux" a tested claim. Two Linux-only defects were green on macOS.

### Fixed
- **Tool payloads larger than ~128 KB failed on Linux.** Linux caps a single `argv` entry at
  `MAX_ARG_STRLEN` (131 072 bytes) regardless of total `ARG_MAX`; macOS has no per-argument
  cap. Passing tool output through `jq --arg` therefore worked on macOS and failed on Linux
  with `Argument list too long`, at the point of building the response — so the client got
  nothing back. Large content now goes to `jq` on stdin and never touches `argv`.
- `tool_book_ticket` required `bc`, which is absent from slim Debian/Ubuntu images. It now
  uses `jq`, which also removes the hand-built JSON string beside it.
- **The HTTP server could not be stopped.** Its accept loop ran `nc | handler` as a
  foreground pipeline, and bash defers trap handling until the foreground command finishes —
  so with `nc` blocked waiting for a connection, `SIGTERM` stayed pending forever and `nc`
  outlived the server holding the port. The pipeline now runs in the background with `wait`,
  which is interruptible. Shutdown is immediate and leaves no orphans; as a side effect the
  HTTP suite dropped from ~2 minutes to ~2 seconds, because stale `nc` processes were no
  longer squatting the port and forcing every request through the retry path.

### Changed
- **BREAKING (internal API)** — `create_response` now reads the result object from **stdin**
  instead of taking it as `$2`. In-tree callers are updated; a custom transport calling
  `create_response "$id" "$result"` must pipe instead.
- The netcat listen syntax (`nc -l PORT` vs `nc -l -p PORT`) is detected by binding a
  scratch port at startup rather than by parsing version strings.
- `base64 -d` with a `-D` fallback, covering GNU, busybox and both modern and older BSD.

### Added
- Two more examples, both running over either transport from a single file:
  `examples/weatherserver.sh` (wrapping a third-party HTTP API — env-var secrets, network
  failure handling, response trimming) and `examples/fileserver.sh` (read-only filesystem
  access with a path-traversal boundary verified against relative traversal, absolute
  paths and symlink escapes).
- `scripts/test-linux.sh` — runs the real suites inside `debian:stable-slim`,
  `alpine:latest` (musl + busybox) and `ubuntu:24.04`, on deliberately minimal images so an
  undeclared dependency fails loudly. Includes a **500 KB payload** assertion, the specific
  regression test for the argv ceiling.
- ADR-0007 and `docs/spikes/spike-03-linux-portability.md`.

### Verified
31/31 unit and 19/19 HTTP tests pass on macOS (bash 3.2 and 5.3), Debian, Alpine and Ubuntu.
Docker is required only to verify other platforms, never to run a server.

## 0.4.0 (2026-08-04)

Adds the second standard transport and a real worked example.

### Added
- `mcpserver_http.sh` — the **Streamable HTTP** transport, scoped as a local endpoint.
  Delegates to the same `process_request` as stdio, so the two bindings cannot drift.
  Enabled per-server with `--http`; both `moviemcpserver.sh` and the new example support it.
- Header↔body enforcement required by the revision: `MCP-Protocol-Version`, `Mcp-Method`
  and `Mcp-Name` (including `=?base64?…?=` decoding) must be present and must match the
  body, else `400` with `-32020 HeaderMismatch`.
- HTTP status mapping (`-32022`/`-32020`/`-32700`/`-32600` → 400, `-32601` → 404,
  notifications → `202`), `405` for GET/DELETE, `Origin` allowlist with `403`, and
  `Mcp-Session-Id` / `Last-Event-ID` ignored rather than rejected.
- Listener backend selection — `socat` (forks per connection) → `ncat` → BSD `nc` — chosen
  at startup and disclosed on stderr, including the one-connection-at-a-time warning.
- `examples/gitserver.sh`: a read-only git server (`git_status`, `git_log`, `git_show`)
  running over both transports from one file, plus `examples/README.md` — a build-your-own
  walkthrough covering tool contracts, input validation, and structured output.
- `test_http_transport.sh`: 19 tests driving a live server over `curl` including the `handle-connection` re-exec
  path and a bash-3.2 framing check.
- ADR-0006 accepting HTTP as a local endpoint; ADR-0001 marked superseded *in scope*.
  `docs/spikes/spike-02-http-listener.{sh,md}` records the evidence.

### Changed
- `moviemcpserver.sh` now dispatches on `--http` instead of calling `run_mcp_server`
  unconditionally.

### Notes
- **Portability constraint discovered while building this**: `/bin/bash` on macOS is bash
  **3.2**, where `read -N` and `declare -A` do not exist — and `read -N` fails *silently*,
  yielding an empty body. The HTTP transport uses `head -c` and flat variables instead.
- The `socat` and `ncat` listener backends are **untested end-to-end** — neither is
  installed on the development machine. The request handling they re-exec is covered.
- The HTTP endpoint has no TLS and no authentication. It binds loopback and validates
  `Origin`; anything beyond localhost needs a reverse proxy in front.

## 0.3.0 (2026-08-04)

Adopts MCP revision **2026-07-28**. This is a breaking release: the protocol itself
removed the handshake this SDK was built around.

### Added
- `server/discover` — required by the revision; advertises supported protocol versions,
  capabilities, instructions and cache hints.
- Per-request protocol version negotiation from
  `params._meta["io.modelcontextprotocol/protocolVersion"]`, answering a mismatch with
  `-32022` and a `data.supported` list.
- `resultType` on every result and `io.modelcontextprotocol/serverInfo` in every result's
  `_meta`.
- `ttlMs` and `cacheScope` on `tools/list` and `server/discover` results.
- `notifications/cancelled` accepted as a silent sink (the stdio cancellation signal).
- `-32700` parse errors for unparseable input.
- Schema conformance test (`test_conformance.sh`) validating live output against the
  vendored official `spec/schema-2026-07-28.json`.
- Architecture decision records in `docs/adr/`, a runnable stdio viability spike in
  `docs/spikes/`, and an OpenSpec change under `openspec/changes/`.

### Changed
- **BREAKING** — A tool returning non-zero now produces a *successful* `CallToolResult`
  with `isError: true` instead of a JSON-RPC `-32603`, so the model sees the failure and
  can self-correct. Tool authors keep the same `echo` + `return 0|1` contract.
- **BREAKING** — "Tool not found" moved from `-32601` to `-32602`, matching the
  revision's realignment of not-found errors onto Invalid Params.
- **BREAKING** — `MCP_CONFIG_FILE` is now a `server/discover` body
  (`supportedVersions`, `capabilities`, `instructions`, `ttlMs`, `cacheScope`,
  `serverInfo`) rather than an `initialize` result.
- Multi-line tool output is preserved instead of being flattened with `tr '\n' ' '`.
- Messages are parsed with one `jq` invocation and responses built with `jq -n --arg`
  rather than string concatenation — 9 `jq` forks per request down to 4, ~48 ms to
  ~34 ms. This also removes a quoting bug where an error message containing a `"` could
  corrupt the response envelope.
- Test suite rewritten: 29 tests, one per spec scenario, with single-test selection
  (`./test_mcpserver_core.sh <test_name>`).

### Removed
- **BREAKING** — `initialize` and `notifications/initialized`. The revision has no
  handshake; clients call `server/discover` and then carry the version on each request.
- **BREAKING** — Clients speaking any revision other than `2026-07-28` are rejected.

## 0.2.0 (2025-05-31)

### Added
- Added Documentation for MCP Server Bash SDK
- Enhanced error handling for tools

## 0.1.0 (2025-05-30)

### Added
- Initial version of MCP Server Bash SDK
- Core MCP server implementation with JSON-RPC 2.0 message handling
- Support for initialize, tools/list, and tools/call methods
- Simple logging mechanism
- Basic error handling for invalid requests, methods not found, and tool execution errors
- Test suite for core functionality

### Features
- Pure Bash implementation with minimal dependencies (jq)
- Support for custom tool implementations
- Configurable logging
