# Spike 03 — Does this actually run on Linux?

**Run it:** `./scripts/test-linux.sh all` (needs Docker). Runs the real suites inside
Debian, Alpine and Ubuntu — deliberately minimal images with only `bash`, `jq`, `curl`,
`git` and a netcat, so a hidden dependency fails instead of silently working.

**Answer: it does now. It did not before — two Linux-only bugs, one of them serious.**

## What broke

### 1. `jq --arg` hits Linux's 128 KB per-argument ceiling — a real bug, not a test artifact

```
/work/mcpserver_core.sh: line 210: /usr/bin/jq: Argument list too long
```

Linux caps a **single** `argv` entry at `MAX_ARG_STRLEN` = 32 pages = **131 072 bytes**,
independently of the much larger total `ARG_MAX`. macOS has no equivalent per-argument cap
(its ~1 MB limit is on the total), so:

- On macOS, a tool returning a 200 KB payload worked.
- On Linux, the identical call failed — and failed *at the point of building the response*,
  so the client got nothing back.

The core was passing tool output through `jq -cn --arg text "$content"`, then passing the
assembled result through `create_response`'s `--argjson result`. Two chances to exceed the
limit on any large payload.

**Fix:** large content never touches `argv`. Tool output is piped to `jq -cRs`, and
`create_response` now reads the result object from **stdin**:

```bash
printf '%s' "$content" \
  | jq -cRs '{content: [{type: "text", text: .}], resultType: "complete"}' \
  | create_response "$id"
```

The regression test now uses 500 KB, comfortably past the ceiling, and runs on every image.

This is the kind of bug that ships: it needs a big payload *and* a Linux host to appear,
and both test suites were green on the development machine.

### 2. `bc` is not installed on Debian slim

`tool_book_ticket` shelled out to `bc` for one multiplication. `bc` is absent from
Debian/Ubuntu slim images and most containers. Replaced with `jq`, which is already a hard
dependency and also removes the hand-built JSON string that sat next to it.

### 3. The HTTP server could not be stopped — a deferred-trap bug

The accept loop ran `nc … | handle_http_request` as a **foreground** pipeline. bash defers
trap handling until the current foreground command finishes, and `nc` blocks until a client
connects — so `SIGTERM` sat pending forever, the trap never ran, and `nc` outlived the
server holding the port.

On macOS this was masked: the test harness's `pkill` happened to reap `nc`, which let the
pipeline finish and the trap fire. On Linux the same `pkill` did not match, so the suite
passed all 19 tests and then **hung forever instead of exiting**.

**Fix:** run the pipeline in the background and `wait` on it. `wait` is interruptible, so
the trap fires immediately:

```bash
{ nc -l "$PORT" <"$fifo" | handle_http_request >"$fifo"; } &
MCP_HTTP_CHILD=$!
wait "$MCP_HTTP_CHILD"
```

Shutdown now takes **0 s** with no orphaned processes, and — because stale `nc` processes
were no longer squatting the port and forcing every request through the retry path — the
HTTP suite went from **~2 minutes to 2 seconds**.

## What was already fine

| Concern | Debian | Alpine (musl/busybox) | Ubuntu | macOS |
| --- | --- | --- | --- | --- |
| `head -c` exact-length body read | ✅ | ✅ | ✅ | ✅ |
| `base64 -d` | ✅ | ✅ | ✅ | ✅ (`-D` fallback kept for older BSD) |
| `nc -l PORT` | ✅ openbsd | ✅ openbsd | ✅ | ✅ BSD |
| FIFO accept loop | ✅ | ✅ | ✅ | ✅ |
| `mkfifo`, `mktemp -u`, `tr`, `date +fmt` | ✅ | ✅ | ✅ | ✅ |

`nc -l PORT` worked on every image tested, but **netcat-traditional and busybox netcat
require `nc -l -p PORT`** and error on the plain form. Rather than sniff version strings,
the transport now binds a scratch port at startup and uses whichever spelling actually
works (`mcp_nc_listen_flag`).

## Results

| Image | bash | Unit | HTTP | Example | 500 KB payload |
| --- | --- | --- | --- | --- | --- |
| Debian stable-slim | 5.2.37 | 31/31 | 19/19 | ✅ | ✅ |
| Alpine (musl, busybox) | 5.3.9 | 31/31 | 19/19 | ✅ | ✅ |
| Ubuntu 24.04 | 5.2 | 31/31 | 19/19 | ✅ | ✅ |
| macOS (bash 3.2 and 5.3) | 3.2.57 / 5.3.9 | 31/31 | 19/19 | ✅ | ✅ |

The two extra unit tests are the guards this spike produced: a 500 KB payload round-trip,
and a check that every script in the repo parses under bash 3.2. The second self-skips where
no bash 3.2 is installed — on the Linux images it is a no-op, and macOS is where it earns
its keep.

## The lesson worth keeping

The two portability traps found across this SDK point in opposite directions, and neither
is caught by reading a man page:

- **macOS is the old-bash platform.** `/bin/bash` is 3.2 — no `read -N`, no `declare -A`,
  no `;&` case fallthrough. These fail *silently* or with confusing syntax errors.
- **Linux is the strict-kernel platform.** `MAX_ARG_STRLEN` rejects a single large argument
  that macOS accepts happily.

Developing on one and deploying on the other hides both. The fix is not vigilance, it is
`./scripts/test-linux.sh` — and the harness itself hit trap #1 on its first run, because it
used `;&` fallthrough and ran under macOS bash 3.2.

## Decisions this spike feeds

- [ADR-0007 — Portability is verified, not asserted](../adr/0007-portability-is-tested.md)
