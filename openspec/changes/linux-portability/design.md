## Context

Development happens on macOS; deployment is mostly Linux. Both existing suites were green
on macOS while the code carried two Linux-only defects. Running the same suites inside a
Debian container found both in one command — see
[spike 03](../../../docs/spikes/spike-03-linux-portability.md).

The serious one: Linux caps a **single** `argv` entry at `MAX_ARG_STRLEN` = 131 072 bytes,
independently of the far larger total `ARG_MAX`. macOS has no per-argument cap. The core
passed tool output through `jq -cn --arg text "$content"` and then the assembled result
through `create_response`'s `--argjson result`, so any tool returning more than ~128 KB
worked on the dev machine and failed in production with `Argument list too long`.

A third defect surfaced while building the harness: the HTTP accept loop ran
`nc … | handler` as a **foreground** pipeline, and bash defers traps until the foreground
command finishes. Since `nc` blocks until a client connects, `SIGTERM` stayed pending
forever — the server could not be stopped and `nc` outlived it holding the port. macOS
masked it (the harness's `pkill` happened to reap `nc`); on Linux the suite passed all 19
tests and then hung instead of exiting.

## Goals / Non-Goals

**Goals:**
- Identical behaviour on macOS (bash 3.2 and 5.x), glibc Linux, and musl/busybox Linux.
- A single command that proves it, runnable by anyone with Docker.
- Keep `jq` as the only runtime dependency.
- A regression test for the argv ceiling specifically, not just "large-ish" input.

**Non-Goals:**
- BSDs other than macOS, Solaris, Windows/WSL.
- A CI workflow file. The script is what CI would invoke; wiring it up is separate.
- Bare-metal Linux differences beyond what the container images represent.

## Decisions

**Result objects travel on stdin, not argv.** `create_response` changes signature from
`create_response <id> <result-json>` to `create_response <id>` reading the result from
stdin, and tool output goes straight into `jq -cRs`. This eliminates the ceiling rather
than raising it: no code path carries unbounded data through an argument any more. Short,
bounded values (error messages, codes, `serverInfo`) stay as `--arg`, which is what it is
for.

The cost is a slightly less obvious calling convention. It is worth it because the failure
mode it removes is platform-dependent, silent on the dev machine, and total on the target.

**Probe, don't sniff.** `mcp_nc_listen_flag` binds a random high port with `nc -l PORT`,
checks whether the process survived, and falls back to `nc -l -p PORT`. Parsing `nc -h`
output would need a table of every netcat fork and would still be wrong for the next one.
Two 0.3 s probes at startup buy correctness on variants nobody enumerated.

**Alpine is in the matrix, not just Debian.** musl plus busybox coreutils is the strictest
common target and where container users actually are. Debian alone would have proven less
than it appeared to.

**The regression test is 500 KB, not 200 KB.** Comfortably past the 128 KB ceiling with
room for the JSON escaping overhead, so the test cannot pass by accident on a platform with
a slightly different limit.

**Minimal images on purpose.** Only `bash`, `jq`, `curl`, `git` and a netcat are installed.
A fuller image would have satisfied the `bc` dependency silently and hidden the bug.

**bash 3.2 is the syntax floor, including for tooling.** `scripts/test-linux.sh` originally
used `;&` case fallthrough and failed immediately under macOS's bash 3.2 — the harness
tripping over the very trap it exists to catch. The rule now covers `scripts/` too.

## Risks / Trade-offs

- **`create_response`'s changed signature** breaks any custom transport calling it with two
  arguments. Internal API, documented as breaking in `VERSIONS.md`; both in-tree transports
  are updated.
- **Docker is now needed for full verification.** It is not needed to run the SDK, so the
  runtime dependency story is unchanged — but "I ran the tests" now means less than "I ran
  the matrix", and only the latter is a portability claim.
- **The matrix costs a few minutes per image**, mostly container setup. It is a
  pre-release gate, not an edit-loop tool.
- **Containers are not every Linux.** glibc and musl are covered, along with the mainstream
  netcat variants. A host with netcat-traditional is handled by the runtime probe but is
  untested end-to-end, because no image in the matrix ships it.
- **`jq -cRs` slurps the whole payload into memory** to build the string, as the previous
  code also did. This change does not make large payloads cheap, only possible.
