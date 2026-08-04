## 1. Groundwork

- [x] 1.1 Vendor the official schema at `spec/schema-2026-07-28.json`
- [x] 1.2 Reshape `assets/movieserver_config.json` into a `DiscoverResult` body
      (`supportedVersions`, `capabilities`, `instructions`, `ttlMs`, `cacheScope`,
      `serverInfo`)

## 2. Core rewrite (`mcpserver_core.sh`)

- [x] 2.1 `parse_message` — one `jq` fork emitting jsonrpc/id/method/protocolVersion/
      toolName/arguments joined by ASCII Unit Separator (not `@tsv`, which escapes
      backslashes and would corrupt the arguments blob)
- [x] 2.2 `create_response` / `create_error_response` built with `jq -n --arg`, injecting
      `resultType` and `_meta` serverInfo
- [x] 2.3 Version gate in `process_request`: `-32022` with `data.requested`/`data.supported`,
      exempting `server/discover`
- [x] 2.4 `handle_discover` for `server/discover`
- [x] 2.5 `handle_tools_list` decorating with `resultType`/`ttlMs`/`cacheScope`
- [x] 2.6 `handle_tools_call` mapping non-zero exit to `isError: true`, missing tool to
      `-32602`, and preserving newlines in tool output
- [x] 2.7 Remove `handle_initialize` and the `notifications/initialized` branch; accept
      `notifications/cancelled` as a silent sink
- [x] 2.8 Parse-error path: `-32700` with `id: null` for unparseable input
- [x] 2.9 Refresh the error-code comment block to the spec's allocation policy

## 3. Reference implementation

- [x] 3.1 `tool_validate_age` returns 1 on a failed check now that failures reach the model
- [x] 3.2 Confirm `assets/movieserver_tools.json` order is deterministic and intentional

## 4. Tests

- [x] 4.1 Fix the two pre-existing failures (test never overrode `MCP_CONFIG_FILE` /
      `MCP_TOOLS_LIST_FILE`, so both fell back to non-existent defaults)
- [x] 4.2 Replace `initialize` tests with `server/discover` tests
- [x] 4.3 Add tests per spec scenario: version gate (supported / unsupported / absent),
      `resultType`, `_meta` serverInfo, cache fields, `isError`, `-32602` for unknown
      tool, `-32600` for illegal name, `-32700` for bad JSON, notification silence
- [x] 4.4 `test_conformance.sh` validating live server output against the vendored
      schema, skipping cleanly when Python `jsonschema` is absent
- [x] 4.5 End-to-end stdio session against `moviemcpserver.sh`
- [x] 4.6 Re-run `docs/spikes/spike-01-stdio-viability.sh` and confirm the parse-path
      improvement predicted by ADR-0004

## 5. Documentation

- [x] 5.1 `readme.md` — new protocol version, `server/discover`, `isError` contract,
      updated config/tools templates
- [x] 5.2 `VERSIONS.md` — 0.3.0 entry marking the breaking changes
- [x] 5.3 `CLAUDE.md` — protocol status section rewritten from "not implemented" to
      "implemented", pointing at the ADRs
