# ADR-0007 — Portability is verified in CI-able containers, not asserted

- **Status:** Accepted
- **Date:** 2026-08-05
- **Evidence:** [Spike 03 — Does this actually run on Linux?](../spikes/spike-03-linux-portability.md)

## Context

The SDK is developed on macOS and deployed mostly on Linux. Both suites were green on the
development machine while the code contained two Linux-only defects, one of which broke any
tool returning more than 128 KB:

- **`MAX_ARG_STRLEN`**: Linux rejects a single `argv` entry over 131 072 bytes regardless of
  total `ARG_MAX`. macOS has no per-argument cap. `jq --arg`/`--argjson` carrying tool
  output therefore worked on the dev machine and failed in production.
- **`bc`** is absent from slim Debian/Ubuntu images; the reference server depended on it.

Neither is discoverable by reading documentation or by careful review. Both are trivially
discoverable by running the tests on the target platform.

The mirror-image trap already exists in the other direction: `/bin/bash` on macOS is
**3.2**, where `read -N`, `declare -A` and `;&` case fallthrough do not exist. The
portability harness written for this ADR tripped over `;&` on its very first run.

## Decision

**Ship `scripts/test-linux.sh` and treat a green run on Linux as part of "done."**

- The real suites run inside `debian:stable-slim`, `alpine:latest` (musl + busybox) and
  `ubuntu:24.04`, with only `bash`, `jq`, `curl`, `git` and a netcat installed — a minimal
  image so an undeclared dependency fails loudly instead of being satisfied by accident.
- The harness also asserts a **500 KB** tool payload round-trips, which is the specific
  regression test for `MAX_ARG_STRLEN`.
- Two rules become binding on all shipped code:
  1. **Never pass unbounded data through `argv`.** Tool output and result objects go to
     `jq` on **stdin**. `--arg` is for short, known-bounded values only.
  2. **Target bash 3.2 syntax.** No `read -N`, no `declare -A`, no `;&`. This applies to
     the scripts in `scripts/` too — they run on the dev machine, which is the old-bash one.
- Platform-variant commands are resolved **empirically at runtime**, not by parsing version
  strings: `mcp_nc_listen_flag` binds a scratch port to learn whether this netcat wants
  `-l PORT` or `-l -p PORT`; `base64 -d` falls back to `-D`.

## Consequences

**Good**

- "Runs on Linux" becomes a reproducible command anyone can run, not a claim.
- The 500 KB assertion locks in the fix for a bug that was invisible on the dev platform and
  fatal on the deployment platform.
- Alpine in the matrix means musl and busybox coreutils are covered, which is the strictest
  common target and where container users actually are.
- Empirical probing beats version sniffing: it survives netcat variants nobody enumerated.

**Bad / accepted**

- Docker becomes a dependency for full verification. It is not needed to *run* the SDK —
  only to check it against other platforms — so `jq` remains the sole runtime dependency.
- The matrix takes a few minutes per image, mostly container setup. Acceptable for a
  pre-release gate; run the native suites while developing.
- Container Linux is not identical to a bare-metal or BSD host. It covers glibc, musl and
  the mainstream netcat variants — not every Unix, and the readme says so rather than
  implying universality.

## Alternatives considered

- **A dependency-checker script** (`command -v` for each tool) — rejected: it would have
  caught the missing `bc` and missed the `MAX_ARG_STRLEN` bug entirely, which was the
  serious one. Checking that tools exist is not the same as running the code.
- **Trusting POSIX/portability review** — rejected on evidence: the defects survived review
  and both test suites. Running on the target platform found both in one command.
- **GitHub Actions matrix instead of local Docker** — complementary, not an alternative.
  The script is what CI would call; it also runs before pushing, which is where the feedback
  is worth most.
