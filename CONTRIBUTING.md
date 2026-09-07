# Contributing

This SDK is one vendorable file plus a thin per-server wrapper. That constraint applies to
contributions too: the bar for adding to `mcpserver_core.sh` is high, the bar for a new
example server or a doc fix is low.

## Before you write code

Design decisions here are backed by evidence, not opinion — see `docs/adr/` for the
decisions and `docs/spikes/` for the measurements behind them. If your change touches
protocol behavior, transport semantics, or anything ADR-0002 through ADR-0007 already
settled, read the relevant ADR first. If you think the tradeoff it recorded is wrong,
open an issue with your case before sending a PR — a good issue with fresh evidence can
change an ADR's outcome; a PR that quietly contradicts one will just get closed as
out-of-scope.

## Running the tests

```bash
./test_mcpserver_core.sh                          # unit tests
./test_mcpserver_core.sh test_discover_shape       # a single test
./test_conformance.sh                              # validates against the official MCP schema
./test_http_transport.sh                           # HTTP transport tests
```

All four should pass clean before you open a PR. If you're touching `mcpserver_http.sh`,
run `test_http_transport.sh` specifically — it's the one that exercises concurrency,
header validation, and the socat/netcat fallback paths.

Run `shellcheck` on anything you touch. The codebase isn't 100% warning-free today (a
couple of existing SC2034/SC2094 notes in `mcpserver_http.sh`), so don't feel obligated to
fix pre-existing warnings in unrelated code — just don't add new ones.

## What a good PR looks like

- **Small and single-purpose.** This file is meant to be read in one sitting; a PR that
  makes it harder to read in one sitting needs a very good reason.
- **Tested.** A bug fix without a regression test that would have caught the bug is an
  incomplete bug fix — see PR #11 for the shape this should take (root cause, a test that
  fails without the fix and passes with it, before/after behavior spelled out).
- **Honest about tradeoffs.** If your change trades one thing for another (the way every
  ADR in this repo does), say so in the PR description instead of only listing what's
  better.

## Where to start

There's no artificial "good first issue" backlog here — the repo is small enough that any
open issue is a reasonable place to start, and the maintainer will point you at the right
file if you ask. Docs fixes, a missing example server, or a test gap you noticed while
reading the code are all welcome without needing to ask first.

## Filing an issue

Reproduce before you report. "It doesn't work" is hard to act on; "here's the exact
request I sent and the exact response I got, here's what I expected instead" gets fixed
fast. If your report involves an MCP client, include the client and the protocol
revision it's speaking — a lot of what looks like a bug here is a version mismatch, and
ADR-0002 explains why that's a deliberate tradeoff rather than an oversight.
