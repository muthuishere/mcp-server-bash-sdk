# ADR-0003 — Conformance is asserted against the published schema, not hand-written strings

- **Status:** Accepted
- **Date:** 2026-08-04

## Context

The existing test suite asserts on substrings: `assert_contains "$response" '"tools"'`.
That proves a key is present somewhere in the bytes. It cannot catch a missing required
`resultType`, a `ttlMs` emitted as a string instead of an integer, or a `cacheScope`
outside its enum — every one of which is a spec violation a real client will reject.

MCP publishes a machine-readable JSON Schema per revision
(`schema/2026-07-28/schema.json`, ~180 KB). It defines exactly the shapes we must emit:
`JSONRPCResultResponse`, `ListToolsResult`, `CallToolResult`, `DiscoverResult`,
`UnsupportedProtocolVersionError`.

## Decision

**Vendor the official schema at `spec/schema-2026-07-28.json` and validate real server
output against it** in a conformance test (`test_conformance.sh`). The bash test suite
keeps its fast substring checks for control flow and error paths; the conformance test
is the arbiter of wire correctness.

Validation shells out to Python's `jsonschema`. The test **skips with a clear message,
not a failure**, when that module is absent, so `jq` remains the only hard dependency for
running the server (ADR-0005) and for the core unit tests.

## Consequences

**Good**

- Spec drift becomes a failing test with a JSON Pointer to the offending field, instead
  of a client-side "malformed response" three months later.
- The vendored file is the exact bytes the spec publishes, so upgrading a revision is a
  file swap plus whatever the diff makes fail.
- It documents intent better than prose: the assertion *is* "we emit a valid
  `ListToolsResult`."

**Bad / accepted**

- ~180 KB of vendored third-party JSON in a repo whose selling point is that it is small.
  Accepted — it is data, not code, and it never runs in the server path.
- Optional Python dependency for full conformance. Contained by making it a skip.
- Vendoring pins us to a revision; the file must be refreshed deliberately when the spec
  moves. That is the point.

## Alternatives considered

- **Fetch the schema at test time** — rejected: makes the suite network-dependent and
  non-reproducible, and silently changes what "passing" means.
- **Validate with `jq` alone** — rejected: `jq` has no JSON Schema evaluator; hand-rolling
  `$ref`/`allOf` resolution would be a bigger program than the SDK.
