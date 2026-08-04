## 1. Find out what actually breaks

- [x] 1.1 Run the existing suites unchanged inside `debian:stable-slim`
- [x] 1.2 Diagnose the two failures: `bc` absent, and `jq: Argument list too long` on a
      200 KB payload
- [x] 1.3 Identify the root cause of the second — Linux `MAX_ARG_STRLEN` (128 KB per argv
      entry), which macOS does not have

## 2. Fix

- [x] 2.1 `create_response` reads the result object from stdin instead of `$2`
- [x] 2.2 Update all three call sites (`handle_discover`, `handle_tools_list`,
      `handle_tools_call`)
- [x] 2.3 Pipe tool output into `jq -cRs` rather than `--arg text`
- [x] 2.4 Replace `bc` with `jq` in `tool_book_ticket`, dropping the hand-built JSON string
- [x] 2.5 `mcp_nc_listen_flag`: probe a scratch port for `nc -l PORT` vs `nc -l -p PORT`
- [x] 2.6 `base64 -d` with `-D` fallback
- [x] 2.7 Run the HTTP accept pipeline in the background and `wait` on it, so `SIGTERM`
      is not deferred behind a blocking `nc`; reap the pipeline's children on shutdown

## 3. Prove it, repeatably

- [x] 3.1 `scripts/test-linux.sh` running the real suites in Docker
- [x] 3.2 Cover Debian (glibc), Alpine (musl + busybox) and Ubuntu
- [x] 3.3 Minimal images — only bash, jq, curl, git, netcat — so a hidden dependency fails
      loudly
- [x] 3.4 Add a 500 KB payload assertion as the regression test for the argv ceiling
- [x] 3.5 Fix the harness's own bash 3.2 violation (`;&` case fallthrough)
- [x] 3.6 Confirm macOS still passes on both bash 3.2 and 5.x

## 4. Write it down

- [x] 4.1 `docs/spikes/spike-03-linux-portability.md` with the failure output and results
      table
- [x] 4.2 ADR-0007 — portability verified, never unbounded data on argv, bash 3.2 floor
- [x] 4.3 Update `docs/adr/README.md`
- [x] 4.4 `readme.md` — supported platforms table and the verification command
- [x] 4.5 `CLAUDE.md` — the two opposing platform traps and the argv rule
- [x] 4.6 `VERSIONS.md` — 0.4.1 entry, marking the `create_response` signature change
