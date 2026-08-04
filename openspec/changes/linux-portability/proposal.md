## Why

The SDK is developed on macOS and deployed mostly on Linux, and nothing verified the second
half of that sentence. Running the existing suites inside Debian found **two Linux-only
defects that were green on the development machine** — one of them fatal for any tool
returning a large payload. Portability was being asserted, not tested.

## What Changes

- **BREAKING (internal)** — `create_response` now reads the result object from **stdin**
  instead of taking it as an argument. Linux caps a single `argv` entry at 128 KB
  (`MAX_ARG_STRLEN`) regardless of total `ARG_MAX`, so `jq --argjson "$result"` failed
  there on payloads that worked fine on macOS. Tool output is now piped to `jq -cRs`.
- Replace `bc` with `jq` in `tool_book_ticket` — `bc` is absent from slim Debian/Ubuntu
  images, and this also removes a hand-built JSON string next to it.
- **Fix a shutdown hang**: the HTTP accept loop ran its `nc | handler` pipeline in the
  foreground, where bash defers trap handling — so `SIGTERM` never fired while `nc` waited
  for a connection, and `nc` outlived the server holding the port. The pipeline now runs in
  the background with `wait`, which is interruptible. Shutdown is instant and leaves no
  orphans; the HTTP suite went from ~2 minutes to ~2 seconds as a side effect.
- Detect the netcat listen syntax empirically at startup (`nc -l PORT` vs `nc -l -p PORT`)
  by binding a scratch port, rather than parsing version strings.
- `base64 -d` with a `-D` fallback, covering GNU, busybox, and both modern and older BSD.
- Add `scripts/test-linux.sh`: runs the real suites in `debian:stable-slim`,
  `alpine:latest` (musl + busybox) and `ubuntu:24.04`, plus a **500 KB payload** assertion
  that is the specific regression test for the `argv` bug.
- Document the two opposing platform traps: macOS is the *old-bash* platform (3.2 — no
  `read -N`, no `declare -A`, no `;&`), Linux is the *strict-kernel* platform
  (`MAX_ARG_STRLEN`).

Not in scope: BSD hosts other than macOS, bare-metal non-container Linux, Windows/WSL, and
a CI pipeline (the script is what CI would call, but no workflow file is added here).

## Capabilities

### New Capabilities
- `platform-portability`: the runtime-environment contract — which shells, coreutils
  variants and netcat flavours the SDK supports, how platform differences are resolved, and
  the argv-size rule that large payloads depend on.

### Modified Capabilities
None. Every existing spec scenario still holds unchanged on every platform — that is the
property this change establishes rather than alters. `test_mcpserver_core.sh` and
`test_http_transport.sh` pass 29/29 and 19/19 on all four platforms without edits.

## Impact

- `mcpserver_core.sh` — `create_response` signature (stdin, not `$2`); all three call sites
  updated; tool output piped rather than passed.
- `mcpserver_http.sh` — `mcp_nc_listen_flag` probe, `base64` fallback.
- `moviemcpserver.sh` — `bc` dependency removed.
- New: `scripts/test-linux.sh`, `docs/spikes/spike-03-linux-portability.md`,
  `docs/adr/0007-portability-is-tested.md`.
- `readme.md`, `CLAUDE.md`, `VERSIONS.md` — supported-platform table and the argv rule.
- **Anyone who wrote a server against this SDK gets the payload fix for free**, but a
  custom transport calling `create_response "$id" "$result"` must switch to piping.
