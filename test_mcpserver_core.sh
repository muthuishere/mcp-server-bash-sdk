#!/bin/bash
# test_mcpserver_core.sh - unit tests for the MCP 2026-07-28 core.
#
# One test per scenario in openspec/changes/adopt-mcp-2026-07-28/specs/.
# Wire-shape correctness is asserted separately, against the published schema,
# by ./test_conformance.sh (ADR-0003).
#
# Run a single test:  ./test_mcpserver_core.sh test_unsupported_protocol_version

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The core falls back to asset paths that do not exist in this repo, so the
# tests must point it at real files -- omitting this is what made the original
# initialize/tools-list tests fail on a clean checkout.
export MCP_CONFIG_FILE="$SCRIPT_DIR/assets/movieserver_config.json"
export MCP_TOOLS_LIST_FILE="$SCRIPT_DIR/assets/movieserver_tools.json"
export MCP_LOG_FILE="$SCRIPT_DIR/logs/test_mcpserver.log"

source "$SCRIPT_DIR/mcpserver_core.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0

PV="2026-07-28"
# A well-formed request envelope for the current revision.
request() { # request <id> <method> [params-json]
    local extra="${3:-}"; [[ -z "$extra" ]] && extra='{}'
    jq -cn --argjson id "$1" --arg method "$2" --argjson extra "$extra" --arg pv "$PV" '
      {jsonrpc: "2.0", id: $id, method: $method,
       params: ($extra + {_meta: {
         "io.modelcontextprotocol/protocolVersion": $pv,
         "io.modelcontextprotocol/clientCapabilities": {},
         "io.modelcontextprotocol/clientInfo": {name: "TestClient", version: "1.0.0"}}})}'
}

call() { # call <id> <tool> [arguments-json]
    local args="${3:-}"; [[ -z "$args" ]] && args='{}'
    request "$1" "tools/call" "$(jq -cn --arg n "$2" --argjson a "$args" '{name: $n, arguments: $a}')"
}

# ---- assertions ----------------------------------------------------------

fail() { echo -e "${RED}  $1${NC}"; return 1; }

assert_jq() { # assert_jq <json> <filter> <expected> <message>
    local actual
    actual=$(jq -cr "$2" <<<"$1" 2>/dev/null)
    [[ "$actual" == "$3" ]] && return 0
    fail "$4: expected '$3', got '$actual'"
}

assert_empty() { # assert_empty <value> <message>
    [[ -z "$1" ]] && return 0
    fail "$2: expected no output, got '$1'"
}

run_test() {
    local name="$1"
    TEST_COUNT=$((TEST_COUNT + 1))
    if "$name" >/dev/null 2>&1 && "$name" >/dev/null; then
        PASS_COUNT=$((PASS_COUNT + 1)); echo -e "${GREEN}PASS${NC} $name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "${RED}FAIL${NC} $name"
        "$name" 2>&1 | grep -v '^$' | sed 's/^/      /'
    fi
}

# ---- mcp-protocol-core: envelope ----------------------------------------

test_invalid_jsonrpc_version() {
    local r; r=$(process_request '{"jsonrpc":"1.0","id":4,"method":"tools/list"}')
    assert_jq "$r" '.error.code' '-32600' "wrong envelope rejected" || return 1
    assert_jq "$r" '.id' '4' "id preserved"
}

test_parse_error_on_garbage() {
    local r; r=$(process_request 'this is not json')
    assert_jq "$r" '.error.code' '-32700' "unparseable input" || return 1
    assert_jq "$r" '.id' 'null' "parse error carries null id"
}

test_blank_line_is_silent() {
    assert_empty "$(process_request '   ')" "blank line"
}

# ---- mcp-protocol-core: version negotiation ------------------------------

test_supported_version_is_processed() {
    local r; r=$(process_request "$(request 1 tools/list)")
    assert_jq "$r" '.result.tools | length > 0' 'true' "supported version processed"
}

test_unsupported_protocol_version() {
    local r
    r=$(process_request '{"jsonrpc":"2.0","id":6,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18"}}}')
    assert_jq "$r" '.error.code' '-32022' "unsupported version" || return 1
    assert_jq "$r" '.error.data.requested' '2025-06-18' "reports requested version" || return 1
    assert_jq "$r" '.error.data.supported' '["2026-07-28"]' "advertises supported versions"
}

test_absent_protocol_version() {
    local r; r=$(process_request '{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}')
    assert_jq "$r" '.error.code' '-32022' "missing version rejected" || return 1
    assert_jq "$r" '.error.data.requested' '' "reports empty requested version"
}

test_version_is_not_remembered_across_requests() {
    process_request "$(request 1 tools/list)" >/dev/null
    local r; r=$(process_request '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-11-25"}}}')
    assert_jq "$r" '.error.code' '-32022' "no cross-request version state"
}

# ---- mcp-protocol-core: server/discover ----------------------------------

test_discover_shape() {
    local r; r=$(process_request "$(request 1 server/discover)")
    assert_jq "$r" '.result.supportedVersions' '["2026-07-28"]' "supportedVersions" || return 1
    assert_jq "$r" '.result.capabilities | type' 'object' "capabilities" || return 1
    assert_jq "$r" '.result.resultType' 'complete' "resultType" || return 1
    assert_jq "$r" '.result.ttlMs | type' 'number' "ttlMs" || return 1
    assert_jq "$r" '.result.cacheScope' 'public' "cacheScope"
}

test_discover_bypasses_version_gate() {
    local r
    r=$(process_request '{"jsonrpc":"2.0","id":9,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1999-01-01"}}}')
    assert_jq "$r" '.result.supportedVersions' '["2026-07-28"]' "discovery answers any version"
}

# ---- mcp-protocol-core: result envelope ----------------------------------

test_result_type_present() {
    local r; r=$(process_request "$(call 1 get_movies)")
    assert_jq "$r" '.result.resultType' 'complete' "resultType on tool result"
}

test_server_info_in_meta() {
    local r; r=$(process_request "$(request 1 tools/list)")
    assert_jq "$r" '.result._meta["io.modelcontextprotocol/serverInfo"].name' 'MovieServer' "serverInfo name" || return 1
    assert_jq "$r" '.result._meta["io.modelcontextprotocol/serverInfo"].version | length > 0' 'true' "serverInfo version"
}

test_tools_list_cache_hints() {
    local r; r=$(process_request "$(request 1 tools/list)")
    assert_jq "$r" '.result.ttlMs | type' 'number' "ttlMs is a number" || return 1
    assert_jq "$r" '.result.ttlMs >= 0' 'true' "ttlMs non-negative" || return 1
    assert_jq "$r" '.result.cacheScope | IN("public","private")' 'true' "cacheScope in enum"
}

test_tools_list_order_is_stable() {
    local a b
    a=$(process_request "$(request 1 tools/list)" | jq -c '.result.tools | map(.name)')
    b=$(process_request "$(request 2 tools/list)" | jq -c '.result.tools | map(.name)')
    [[ "$a" == "$b" && -n "$a" ]] && return 0
    fail "tool order not deterministic: '$a' vs '$b'"
}

test_method_not_found() {
    local r; r=$(process_request "$(request 5 resources/list)")
    assert_jq "$r" '.error.code' '-32601' "unknown method"
}

# ---- mcp-protocol-core: notifications ------------------------------------

test_cancelled_notification_is_silent() {
    assert_empty "$(process_request '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}')" "cancellation"
}

test_unknown_notification_is_silent() {
    assert_empty "$(process_request '{"jsonrpc":"2.0","method":"notifications/whatever"}')" "unknown notification"
}

# ---- tool-dispatch -------------------------------------------------------

test_tool_success_is_content_result() {
    local r; r=$(process_request "$(call 3 get_movies)")
    assert_jq "$r" '.result.content[0].type' 'text' "content type" || return 1
    assert_jq "$r" '.result.content[0].text | fromjson | length' '4' "tool payload intact" || return 1
    assert_jq "$r" '.result.isError // false' 'false' "not flagged as error"
}

test_tool_receives_arguments() {
    local r; r=$(process_request "$(call 3 book_ticket '{"movieId":1,"showTime":"10:00","numTickets":2}')")
    assert_jq "$r" '.result.content[0].text | fromjson | .numTickets' '2' "arguments passed through"
}

test_tool_failure_is_iserror_result() {
    local r; r=$(process_request "$(call 4 book_ticket '{"movieId":"abc"}')")
    assert_jq "$r" '.error' 'null' "not a protocol error" || return 1
    assert_jq "$r" '.result.isError' 'true' "isError set" || return 1
    assert_jq "$r" '.result.content[0].text' 'Invalid movieId: must be a number' "reason reaches the model"
}

test_silent_tool_failure_still_reports() {
    tool_silent_failure() { return 1; }
    local r; r=$(process_request "$(call 4 silent_failure)")
    assert_jq "$r" '.result.isError' 'true' "isError set" || return 1
    assert_jq "$r" '.result.content[0].text | length > 0' 'true' "generic message supplied"
}

test_invalid_tool_name() {
    local r; r=$(process_request "$(call 6 'invalid-tool-name!')")
    assert_jq "$r" '.error.code' '-32600' "illegal characters rejected"
}

test_unknown_tool() {
    local r; r=$(process_request "$(call 7 no_such_tool)")
    assert_jq "$r" '.error.code' '-32602' "unknown tool is invalid params"
}

test_missing_arguments_default_to_empty_object() {
    tool_echo_args() { echo "$1"; return 0; }
    local r; r=$(process_request "$(request 8 tools/call '{"name":"echo_args"}')")
    assert_jq "$r" '.result.content[0].text' '{}' "absent arguments become {}"
}

# ---- stdio-transport -----------------------------------------------------

test_multiline_tool_output_is_preserved() {
    tool_multiline() { printf 'line one\nline two\nline three'; return 0; }
    local r; r=$(process_request "$(call 9 multiline)")
    # One physical line on the wire...
    [[ $(wc -l <<<"$r") -eq 1 ]] || fail "response spanned multiple lines" || return 1
    # ...but the newlines survive inside the JSON string.
    assert_jq "$r" '.result.content[0].text | split("\n") | length' '3' "newlines preserved"
}

test_large_payload_round_trip() {
    tool_big() { jq -rn '"x" * 200000'; return 0; }
    local r; r=$(process_request "$(call 10 big)")
    assert_jq "$r" '.result.content[0].text | length' '200000' "200 KB payload intact"
}

test_missing_config_file_is_a_protocol_error() {
    local saved="$MCP_TOOLS_LIST_FILE"
    MCP_TOOLS_LIST_FILE="$SCRIPT_DIR/assets/definitely-not-here.json"
    local r; r=$(process_request "$(request 11 tools/list)")
    MCP_TOOLS_LIST_FILE="$saved"
    assert_jq "$r" '.error.code' '-32603' "missing tools file" || return 1
    assert_jq "$r" '.result' 'null' "no malformed result emitted"
}

test_every_stdout_line_is_json() {
    local out
    out=$( { request 1 tools/list; call 2 get_movies; echo 'garbage'; request 3 server/discover; } | bash "$SCRIPT_DIR/moviemcpserver.sh" )
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        jq -e . >/dev/null 2>&1 <<<"$line" || fail "non-JSON on stdout: $line" || return 1
    done <<<"$out"
    [[ $(grep -c . <<<"$out") -eq 4 ]] || fail "expected 4 response lines, got $(grep -c . <<<"$out")"
}

test_server_exits_on_eof() {
    request 1 tools/list | bash "$SCRIPT_DIR/moviemcpserver.sh" >/dev/null 2>&1
    [[ $? -eq 0 ]] && return 0
    fail "server did not exit 0 on stdin EOF"
}

test_final_line_without_newline_is_processed() {
    local out
    out=$(printf '%s' "$(request 1 tools/list)" | bash "$SCRIPT_DIR/moviemcpserver.sh")
    assert_jq "$out" '.id' '1' "unterminated final line still answered"
}

# ---- portability ---------------------------------------------------------

# macOS resolves `#!/bin/bash` to bash 3.2, where `read -N`, `declare -A` and
# `;&` case fallthrough do not exist -- and fail silently or with a confusing
# syntax error. This applies to development scripts too: the Linux test harness
# tripped over `;&` on its first run (ADR-0007).
test_all_scripts_parse_under_bash_3_2() {
    [[ -x /bin/bash ]] || return 0
    case "$(/bin/bash --version | head -1)" in
    *"version 3."*) ;;
    *) return 0 ;;  # no old bash here to check against
    esac

    local f errors=""
    for f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/examples/*.sh "$SCRIPT_DIR"/scripts/*.sh; do
        [[ -f "$f" ]] || continue
        /bin/bash -n "$f" 2>/dev/null || errors="$errors $(basename "$f")"
    done

    [[ -z "$errors" ]] && return 0
    fail "these do not parse under bash 3.2:$errors"
}

# The Linux per-argument ceiling (MAX_ARG_STRLEN, 128 KB) does not exist on
# macOS, so a payload this size passes locally whatever the code does. The test
# still earns its place here: it fails loudly on Linux if result-building ever
# regresses to passing content through argv.
test_payload_beyond_linux_argv_limit() {
    tool_beyond_argv_limit() { jq -rn '"x" * 500000'; return 0; }
    local r; r=$(process_request "$(call 20 beyond_argv_limit)")
    assert_jq "$r" '.result.content[0].text | length' '500000' "500 KB payload intact"
}

# ---- runner --------------------------------------------------------------

ALL_TESTS=(
    test_invalid_jsonrpc_version
    test_parse_error_on_garbage
    test_blank_line_is_silent
    test_supported_version_is_processed
    test_unsupported_protocol_version
    test_absent_protocol_version
    test_version_is_not_remembered_across_requests
    test_discover_shape
    test_discover_bypasses_version_gate
    test_result_type_present
    test_server_info_in_meta
    test_tools_list_cache_hints
    test_tools_list_order_is_stable
    test_method_not_found
    test_cancelled_notification_is_silent
    test_unknown_notification_is_silent
    test_tool_success_is_content_result
    test_tool_receives_arguments
    test_tool_failure_is_iserror_result
    test_silent_tool_failure_still_reports
    test_invalid_tool_name
    test_unknown_tool
    test_missing_arguments_default_to_empty_object
    test_multiline_tool_output_is_preserved
    test_large_payload_round_trip
    test_missing_config_file_is_a_protocol_error
    test_every_stdout_line_is_json
    test_server_exits_on_eof
    test_final_line_without_newline_is_processed
    test_all_scripts_parse_under_bash_3_2
    test_payload_beyond_linux_argv_limit
)

main() {
    mkdir -p "$(dirname "$MCP_LOG_FILE")"; : >"$MCP_LOG_FILE"

    # The suite drives the core directly, so it needs the movie tools in scope.
    # Sourcing the implementation would start its server loop and repoint the
    # MCP_* paths, so lift out only the tool functions: drop the config
    # assignments, the source lines, and everything from the entry point down.
    eval "$(sed '/^# Start the MCP server/,$d; /^source /d; /^MCP_/d' "$SCRIPT_DIR/moviemcpserver.sh")"

    local tests=("${ALL_TESTS[@]}")
    [[ $# -gt 0 ]] && tests=("$@")

    echo -e "\n${YELLOW}MCP core tests - protocol $MCP_PROTOCOL_VERSION${NC}\n"
    for t in "${tests[@]}"; do run_test "$t"; done

    echo -e "\n${YELLOW}$PASS_COUNT/$TEST_COUNT passed${NC}"
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "${RED}$FAIL_COUNT failed${NC} (log: $MCP_LOG_FILE)"
        exit 1
    fi
    echo -e "${GREEN}All tests passed${NC}"
}

main "$@"
