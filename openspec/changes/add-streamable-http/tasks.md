## 1. Spike

- [x] 1.1 `docs/spikes/spike-02-http-listener.sh` — listener availability, HTTP parsing on
      bash 3.2 vs 5.x, FIFO accept loop, per-request cost, concurrency behaviour
- [x] 1.2 Write up `spike-02-http-listener.md` with the `read -N` / bash 3.2 finding

## 2. Decision

- [x] 2.1 ADR-0006 accepting Streamable HTTP as a local endpoint
- [x] 2.2 Mark ADR-0001 superseded *in scope*, keeping its stdio analysis in force
- [x] 2.3 Update `docs/adr/README.md`

## 3. Transport (`mcpserver_http.sh`)

- [x] 3.1 HTTP request parsing: request line, headers without `declare -A`, body via
      `head -c` (never `read -N`)
- [x] 3.2 Response writers for JSON, empty, and JSON-RPC-error-in-HTTP-error
- [x] 3.3 `Origin` allowlist → 403; loopback bind by default
- [x] 3.4 POST-only; 405 for GET/DELETE; 404 for any other path
- [x] 3.5 Header↔body validation → 400 `-32020`, including `=?base64?…?=` decoding of
      `Mcp-Name`
- [x] 3.6 Notification → 202 with no body
- [x] 3.7 Delegate to `process_request`; map `-32022`/`-32020`/`-32700`/`-32600` → 400,
      `-32601` → 404, else 200
- [x] 3.8 Ignore `Mcp-Session-Id` and `Last-Event-ID`
- [x] 3.9 Backend selection socat → ncat → nc, disclosed on stderr, with the
      one-connection-at-a-time warning

## 4. Example

- [x] 4.1 `examples/gitserver.sh` with `git_status`, `git_log`, `git_show`, argument
      validation, and `--http` dispatch
- [x] 4.2 `examples/assets/gitserver_{config,tools}.json`
- [x] 4.3 `examples/README.md` — build-a-server walkthrough plus both run modes
- [x] 4.4 `--http` on `moviemcpserver.sh` too, so the quick-start server also demonstrates it

## 5. Tests

- [x] 5.1 `test_http_transport.sh` — 19 tests against a live server over curl, including
      the socat/ncat `handle-connection` re-exec path and a bash-3.2 framing check
- [x] 5.2 Cover every spec scenario: headers, statuses, origin, legacy headers, notification,
      base64 sentinel, wrong path
- [x] 5.3 Retry around the `nc` re-arm window rather than pretending it does not exist
- [x] 5.4 Skip cleanly when curl or a listener is unavailable

## 6. Documentation

- [x] 6.1 `readme.md` — HTTP transport section, honest limitations, both examples
- [x] 6.2 `CLAUDE.md` — transport layer, bash 3.2 constraints, test commands
- [x] 6.3 `VERSIONS.md` — 0.4.0 entry
