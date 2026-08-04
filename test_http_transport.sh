#!/bin/bash
# test_http_transport.sh - Streamable HTTP transport tests (ADR-0006).
#
# Starts a real server on a random high port, drives it with curl, asserts
# both the HTTP status and the JSON-RPC body. Protocol semantics are already
# covered by test_mcpserver_core.sh; what is under test here is the HTTP
# binding: header/body validation, status-code mapping, Origin checks, and
# the legacy-traffic answers.
#
# Run a single test:  ./test_http_transport.sh test_mcp_name_mismatch

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$SCRIPT_DIR/examples/gitserver.sh"
PORT="${PORT:-19$((RANDOM % 900 + 100))}"
URL="http://127.0.0.1:$PORT/mcp"
PV="2026-07-28"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0
SERVER_PID=""

META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'

fail() { echo -e "${RED}  $1${NC}"; return 1; }

# The nc backend serves one connection at a time and re-arms between them, so
# a request can land in the window where the port is closed. Retry briefly
# rather than pretending that window does not exist (see spike 02).
http() { # http <curl args...>; sets HTTP_STATUS and HTTP_BODY
    local attempt out
    for attempt in 1 2 3 4 5; do
        out=$(curl -s -m 5 -w '\n%{http_code}' "$@" 2>/dev/null)
        HTTP_STATUS="${out##*$'\n'}"
        HTTP_BODY="${out%$'\n'*}"
        [[ -n "$HTTP_STATUS" && "$HTTP_STATUS" != "000" ]] && return 0
        sleep 0.3
    done
    HTTP_STATUS="000"; HTTP_BODY=""
    return 1
}

assert_status() { [[ "$HTTP_STATUS" == "$1" ]] || fail "$2: expected HTTP $1, got $HTTP_STATUS"; }
assert_jq() {
    local actual; actual=$(jq -cr "$1" <<<"$HTTP_BODY" 2>/dev/null)
    [[ "$actual" == "$2" ]] || fail "$3: expected '$2', got '$actual'"
}

start_server() {
    MCP_HTTP_PORT="$PORT" MCP_LOG_FILE="$SCRIPT_DIR/logs/test_http.log" \
        "$SERVER" --http >/dev/null 2>"$SCRIPT_DIR/logs/test_http.stderr" &
    SERVER_PID=$!
    local i
    for i in $(seq 1 30); do
        curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/mcp" 2>/dev/null && return 0
        sleep 0.2
    done
    # The port refuses between connections, so a failed probe is not fatal.
    return 0
}

stop_server() {
    # The server spawns a pipeline (nc | handler), so killing only the top
    # process leaves orphans holding the port -- harmless on macOS, but on Linux
    # they keep this script from ever exiting.
    if [[ -n "$SERVER_PID" ]]; then
        kill -TERM "$SERVER_PID" 2>/dev/null
        pkill -P "$SERVER_PID" 2>/dev/null
    fi
    pkill -f "nc -l $PORT\$" 2>/dev/null
    pkill -f "nc -l -p $PORT\$" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    return 0
}

# ---- happy path ----------------------------------------------------------

test_discover_over_http() {
    http -X POST "$URL" -H "MCP-Protocol-Version: $PV" -H 'Mcp-Method: server/discover' \
        -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{'"$META"'}}'
    assert_status 200 "discover" || return 1
    assert_jq '.result.supportedVersions' '["2026-07-28"]' "supported versions" || return 1
    assert_jq '.result._meta["io.modelcontextprotocol/serverInfo"].name' 'GitServer' "serverInfo"
}

test_tools_call_over_http() {
    http -X POST "$URL" -H "MCP-Protocol-Version: $PV" -H 'Mcp-Method: tools/call' -H 'Mcp-Name: git_status' \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"git_status","arguments":{},'"$META"'}}'
    assert_status 200 "tools/call" || return 1
    assert_jq '.result.resultType' 'complete' "resultType" || return 1
    assert_jq '.result.content[0].text | fromjson | has("branch")' 'true' "tool payload"
}

test_base64_mcp_name_is_decoded() {
    local encoded; encoded=$(printf 'git_status' | base64)
    http -X POST "$URL" -H "MCP-Protocol-Version: $PV" -H 'Mcp-Method: tools/call' \
        -H "Mcp-Name: =?base64?${encoded}?=" \
        -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"git_status","arguments":{},'"$META"'}}'
    assert_status 200 "base64 sentinel accepted" || return 1
    assert_jq '.error' 'null' "no header mismatch"
}

# ---- header/body validation (-32020) -------------------------------------

test_mcp_name_mismatch() {
    http -X POST "$URL" -H "MCP-Protocol-Version: $PV" -H 'Mcp-Method: tools/call' -H 'Mcp-Name: something_else' \
        -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"git_status","arguments":{},'"$META"'}}'
    assert_status 400 "name mismatch" || return 1
    assert_jq '.error.code' '-32020' "HeaderMismatch code"
}

test_missing_mcp_method_header() {
    http -X POST "$URL" -H "MCP-Protocol-Version: $PV" \
        -d '{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{'"$META"'}}'
    assert_status 400 "missing Mcp-Method" || return 1
    assert_jq '.error.code' '-32020' "HeaderMismatch code"
}

test_missing_protocol_version_header() {
    http -X POST "$URL" -H 'Mcp-Method: tools/list' \
        -d '{"jsonrpc":"2.0","id":6,"method":"tools/list","params":{'"$META"'}}'
    assert_status 400 "missing version header" || return 1
    assert_jq '.error.code' '-32020' "HeaderMismatch code"
}

test_protocol_version_header_body_mismatch() {
    http -X POST "$URL" -H 'MCP-Protocol-Version: 2025-06-18' -H 'Mcp-Method: tools/list' \
        -d '{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{'"$META"'}}'
    assert_status 400 "version header != body" || return 1
    assert_jq '.error.code' '-32020' "HeaderMismatch, not UnsupportedVersion"
}

# ---- protocol errors mapped onto HTTP statuses ---------------------------

test_unsupported_version_is_400_32022() {
    http -X POST "$URL" -H 'MCP-Protocol-Version: 2025-06-18' -H 'Mcp-Method: tools/list' \
        -d '{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18","io.modelcontextprotocol/clientCapabilities":{}}}}'
    assert_status 400 "unsupported version" || return 1
    assert_jq '.error.code' '-32022' "UnsupportedProtocolVersion" || return 1
    assert_jq '.error.data.supported' '["2026-07-28"]' "advertises supported versions"
}

test_unknown_method_is_404() {
    http -X POST "$URL" -H "MCP-Protocol-Version: $PV" -H 'Mcp-Method: resources/list' \
        -d '{"jsonrpc":"2.0","id":9,"method":"resources/list","params":{'"$META"'}}'
    assert_status 404 "unknown method" || return 1
    assert_jq '.error.code' '-32601' "method not found in body"
}

test_malformed_json_is_400() {
    http -X POST "$URL" -H "MCP-Protocol-Version: $PV" -H 'Mcp-Method: tools/list' -d 'not json'
    assert_status 400 "malformed body" || return 1
    assert_jq '.error.code' '-32700' "parse error"
}

# ---- transport rules -----------------------------------------------------

test_notification_is_202_with_no_body() {
    http -X POST "$URL" -H "MCP-Protocol-Version: $PV" -H 'Mcp-Method: notifications/cancelled' \
        -d '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}'
    assert_status 202 "notification accepted" || return 1
    [[ -z "${HTTP_BODY//[[:space:]]/}" ]] || fail "notification returned a body: $HTTP_BODY"
}

test_get_is_405() {
    http -X GET "$URL"
    assert_status 405 "GET has no meaning in this revision"
}

test_delete_is_405() {
    http -X DELETE "$URL"
    assert_status 405 "DELETE was the session teardown, now gone"
}

test_bad_origin_is_403() {
    http -X POST "$URL" -H "MCP-Protocol-Version: $PV" -H 'Mcp-Method: tools/list' \
        -H 'Origin: https://evil.example' \
        -d '{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{'"$META"'}}'
    assert_status 403 "DNS-rebinding protection"
}

test_allowed_origin_passes() {
    http -X POST "$URL" -H "MCP-Protocol-Version: $PV" -H 'Mcp-Method: tools/list' \
        -H 'Origin: http://localhost:5173' \
        -d '{"jsonrpc":"2.0","id":11,"method":"tools/list","params":{'"$META"'}}'
    assert_status 200 "localhost origin allowed"
}

test_legacy_session_headers_are_ignored() {
    http -X POST "$URL" -H "MCP-Protocol-Version: $PV" -H 'Mcp-Method: tools/list' \
        -H 'Mcp-Session-Id: stale-session' -H 'Last-Event-ID: 7' \
        -d '{"jsonrpc":"2.0","id":12,"method":"tools/list","params":{'"$META"'}}'
    assert_status 200 "legacy headers ignored, not rejected" || return 1
    assert_jq '.result.tools | length > 0' 'true' "request still served"
}

# The socat and ncat backends re-exec the server as `handle-connection` and
# hand it one connection on stdin. Neither tool is installed on every dev box,
# so drive that entry point directly rather than leaving it untested.
test_handle_connection_entry_point() {
    local body out
    body='{"jsonrpc":"2.0","id":14,"method":"tools/list","params":{'"$META"'}}'
    out=$(printf 'POST /mcp HTTP/1.1\r\nHost: localhost\r\nMCP-Protocol-Version: %s\r\nMcp-Method: tools/list\r\nContent-Length: %d\r\n\r\n%s' \
        "$PV" "${#body}" "$body" | "$SERVER" handle-connection)

    [[ "$out" == "HTTP/1.1 200 OK"* ]] || fail "expected a 200 status line, got: ${out%%$'\r'*}" || return 1
    HTTP_BODY="${out#*$'\r\n\r\n'}"
    assert_jq '.result.tools | length > 0' 'true' "tools returned through the re-exec path"
}

# Same path, under the bash a macOS `#!/bin/bash` script actually gets. `read -N`
# and `declare -A` do not exist there and fail silently (spike 02).
test_works_on_bash_3_2() {
    [[ -x /bin/bash ]] || return 0
    case "$(/bin/bash --version | head -1)" in
    *"version 3."*) ;;
    *) return 0 ;;  # not an old bash; nothing to prove here
    esac

    local body out
    body='{"jsonrpc":"2.0","id":15,"method":"tools/list","params":{'"$META"'}}'
    out=$(printf 'POST /mcp HTTP/1.1\r\nHost: localhost\r\nMCP-Protocol-Version: %s\r\nMcp-Method: tools/list\r\nContent-Length: %d\r\n\r\n%s' \
        "$PV" "${#body}" "$body" | /bin/bash "$SERVER" handle-connection)

    HTTP_BODY="${out#*$'\r\n\r\n'}"
    assert_jq '.result.tools | length > 0' 'true' "body framing works on bash 3.2"
}

test_wrong_path_is_404() {
    http -X POST "http://127.0.0.1:$PORT/not-the-endpoint" -H "MCP-Protocol-Version: $PV" -H 'Mcp-Method: tools/list' \
        -d '{"jsonrpc":"2.0","id":13,"method":"tools/list","params":{'"$META"'}}'
    assert_status 404 "wrong path"
}

# ---- runner --------------------------------------------------------------

ALL_TESTS=(
    test_discover_over_http
    test_tools_call_over_http
    test_base64_mcp_name_is_decoded
    test_mcp_name_mismatch
    test_missing_mcp_method_header
    test_missing_protocol_version_header
    test_protocol_version_header_body_mismatch
    test_unsupported_version_is_400_32022
    test_unknown_method_is_404
    test_malformed_json_is_400
    test_notification_is_202_with_no_body
    test_get_is_405
    test_delete_is_405
    test_bad_origin_is_403
    test_allowed_origin_passes
    test_legacy_session_headers_are_ignored
    test_wrong_path_is_404
    test_handle_connection_entry_point
    test_works_on_bash_3_2
)

run_test() {
    local name="$1"
    TEST_COUNT=$((TEST_COUNT + 1))
    if "$name" >/dev/null 2>&1; then
        PASS_COUNT=$((PASS_COUNT + 1)); echo -e "${GREEN}PASS${NC} $name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "${RED}FAIL${NC} $name"
        "$name" 2>&1 | grep -v '^$' | sed 's/^/      /'
    fi
}

main() {
    command -v curl >/dev/null || { echo -e "${YELLOW}SKIP${NC} HTTP tests: curl not found"; exit 0; }
    command -v nc >/dev/null || command -v socat >/dev/null || {
        echo -e "${YELLOW}SKIP${NC} HTTP tests: no listener (install socat or netcat)"; exit 0; }

    mkdir -p "$SCRIPT_DIR/logs"
    trap stop_server EXIT

    echo -e "\n${YELLOW}Streamable HTTP transport tests - port $PORT${NC}"
    start_server
    echo -e "backend: $(grep -o 'backend: [a-z]*' "$SCRIPT_DIR/logs/test_http.stderr" 2>/dev/null | head -1 | cut -d' ' -f2)\n"

    local tests=("${ALL_TESTS[@]}")
    [[ $# -gt 0 ]] && tests=("$@")
    for t in "${tests[@]}"; do run_test "$t"; done

    echo -e "\n${YELLOW}$PASS_COUNT/$TEST_COUNT passed${NC}"
    [[ $FAIL_COUNT -gt 0 ]] && { echo -e "${RED}$FAIL_COUNT failed${NC}"; exit 1; }
    echo -e "${GREEN}All HTTP transport tests passed${NC}"
}

main "$@"
