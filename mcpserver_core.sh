#!/bin/bash
# mcpserver_core.sh - Model Context Protocol server core, revision 2026-07-28.
#
# Implements the stdio binding only (ADR-0001) and the 2026-07-28 revision only
# (ADR-0002): no initialize handshake, no sessions, no server-initiated requests.
# Every request carries its own protocol version in params._meta.
#
# This file defines functions and starts nothing. An implementation script sets
# the MCP_* paths, sources this file, defines tool_<name> functions, and calls
# run_mcp_server.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The one protocol revision this server speaks.
MCP_PROTOCOL_VERSION="2026-07-28"

# Configuration paths - overridable by implementations BEFORE sourcing this file.
MCP_CONFIG_FILE="${MCP_CONFIG_FILE:-"$SCRIPT_DIR/assets/mcpserverconfig.json"}"
MCP_TOOLS_LIST_FILE="${MCP_TOOLS_LIST_FILE:-"$SCRIPT_DIR/assets/tools_list.json"}"
MCP_LOG_FILE="${MCP_LOG_FILE:-"$SCRIPT_DIR/mcpserver.log"}"

# Cache hints for list-style results when the config does not state them.
MCP_DEFAULT_TTL_MS="${MCP_DEFAULT_TTL_MS:-60000}"
MCP_DEFAULT_CACHE_SCOPE="${MCP_DEFAULT_CACHE_SCOPE:-public}"

# Field separator used to hand parsed fields from jq back to bash. Unit
# Separator (0x1f) cannot appear unescaped inside JSON text.
readonly MCP_FS=$'\x1f'

# ==== Logging =============================================================
# stdout carries protocol traffic only, so diagnostics go to a file. Set
# MCP_LOG_STDERR=1 to mirror them to stderr, which the spec explicitly allows.

log() {
    local level="$1" message="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    mkdir -p "$(dirname "$MCP_LOG_FILE")"
    echo "[$timestamp] [$level] $message" >>"$MCP_LOG_FILE"
    [[ "${MCP_LOG_STDERR:-0}" == "1" ]] && echo "[$level] $message" >&2
    return 0
}

# Read a JSON file as one compact line. Prints nothing and returns 1 if the
# file is missing or malformed, so callers can raise a protocol error instead
# of emitting a broken result.
read_json_file() {
    local file_path="$1"
    if [[ ! -f "$file_path" ]]; then
        log "ERROR" "Config file not found: $file_path"
        return 1
    fi
    if ! jq -c '.' "$file_path" 2>/dev/null; then
        log "ERROR" "Config file is not valid JSON: $file_path"
        return 1
    fi
}

# The server's identity, echoed in every result's _meta. Cached after the first
# read so it costs one jq fork per process, not one per response.
MCP_SERVER_INFO=""
mcp_server_info() {
    if [[ -z "$MCP_SERVER_INFO" ]]; then
        MCP_SERVER_INFO=$(jq -c '.serverInfo // empty' "$MCP_CONFIG_FILE" 2>/dev/null)
        [[ -z "$MCP_SERVER_INFO" ]] && MCP_SERVER_INFO='{"name":"BashMCPServer","version":"0.0.0"}'
    fi
    echo "$MCP_SERVER_INFO"
}

# ==== Response construction ==============================================
# Built with `jq --arg` rather than string concatenation, so quoting is jq's
# problem and a message containing a quote cannot corrupt the envelope.
#
# The result object arrives on STDIN, never as an argument. Linux caps a single
# argv entry at 128 KB (MAX_ARG_STRLEN) regardless of total ARG_MAX, so passing
# a large tool result through `--argjson` fails there while working fine on
# macOS -- a platform-specific bug that only shows up on big payloads.

# create_response <id-json>   -- result JSON on stdin
# Injects the required resultType and the _meta serverInfo the revision expects.
create_response() {
    local id="$1" response

    response=$(jq -c \
        --argjson id "$id" \
        --argjson serverInfo "$(mcp_server_info)" '
        {
          jsonrpc: "2.0",
          id: $id,
          result: (.
            | .resultType = (.resultType // "complete")
            | ._meta = ((._meta // {}) + {"io.modelcontextprotocol/serverInfo": $serverInfo}))
        }') || {
        log "ERROR" "Failed to build response for id $id"
        return 1
    }

    log "RESPONSE" "$response"
    echo "$response"
}

# create_error_response <id-json> <code> <message> [data-json]
create_error_response() {
    local id="$1" code="$2" message="$3" data="${4:-null}" response

    response=$(jq -cn \
        --argjson id "$id" \
        --argjson code "$code" \
        --arg message "$message" \
        --argjson data "$data" '
        {
          jsonrpc: "2.0",
          id: $id,
          error: ({code: $code, message: $message}
            + (if $data == null then {} else {data: $data} end))
        }')

    log "ERROR" "$response"
    echo "$response"
}

# ==== MCP method handlers ================================================

# server/discover - a MUST in this revision. Advertises supported protocol
# versions, capabilities and cache hints so a client can negotiate without a
# handshake. Deliberately exempt from the version gate: this is the method a
# client calls precisely because it does not yet know what we speak.
handle_discover() {
    local id="$1" config result

    if ! config=$(read_json_file "$MCP_CONFIG_FILE"); then
        create_error_response "$id" -32603 "Server configuration unavailable"
        return
    fi

    result=$(jq -c \
        --arg version "$MCP_PROTOCOL_VERSION" \
        --argjson ttl "$MCP_DEFAULT_TTL_MS" \
        --arg scope "$MCP_DEFAULT_CACHE_SCOPE" '
        {
          supportedVersions: (.supportedVersions // [$version]),
          capabilities: (.capabilities // {}),
          ttlMs: (.ttlMs // $ttl),
          cacheScope: (.cacheScope // $scope),
          resultType: "complete"
        }
        + (if .instructions then {instructions: .instructions} else {} end)
        ' <<<"$config")

    printf '%s' "$result" | create_response "$id"
}

# tools/list - the tools file stays a plain {"tools":[...]} so authors are not
# asked to hand-write cache fields; the core decorates it.
handle_tools_list() {
    local id="$1" tools_doc result

    if ! tools_doc=$(read_json_file "$MCP_TOOLS_LIST_FILE"); then
        create_error_response "$id" -32603 "Tool list unavailable"
        return
    fi

    result=$(jq -c \
        --argjson ttl "$MCP_DEFAULT_TTL_MS" \
        --arg scope "$MCP_DEFAULT_CACHE_SCOPE" '
        {
          tools: (.tools // []),
          ttlMs: (.ttlMs // $ttl),
          cacheScope: (.cacheScope // $scope),
          resultType: "complete"
        }' <<<"$tools_doc")

    printf '%s' "$result" | create_response "$id"
}

# tools/call - dispatches to the tool_<name> shell function.
#
# Error handling follows ADR-0005: a failure *inside* a tool is reported to the
# model as a result with isError=true so it can self-correct, while a failure to
# *find* the tool is a protocol error.
handle_tools_call() {
    local id="$1" tool_name="$2" arguments="$3"
    local content status

    log "INFO" "Tool call: $tool_name with arguments: $arguments"

    # Names are validated before dispatch so a call can never resolve to an
    # arbitrary shell function.
    if ! [[ "$tool_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        create_error_response "$id" -32600 "Invalid tool name format: $tool_name"
        return
    fi

    if ! type "tool_${tool_name}" &>/dev/null; then
        create_error_response "$id" -32602 "Tool not found: $tool_name"
        return
    fi

    content=$("tool_${tool_name}" "$arguments")
    status=$?

    # Tool output goes to jq on STDIN, not through --arg: it can be arbitrarily
    # large and Linux rejects any single argv entry over 128 KB.
    # `-R -s` slurps it as one raw string, escaping newlines as \n inside the
    # JSON string -- satisfying the transport's no-embedded-newline rule without
    # destroying the formatting.
    if [[ $status -ne 0 ]]; then
        log "INFO" "Tool $tool_name reported failure (exit $status)"
        [[ -z "$content" ]] && content="Tool '$tool_name' failed with exit status $status"
        printf '%s' "$content" \
            | jq -cRs '{content: [{type: "text", text: .}], isError: true, resultType: "complete"}' \
            | create_response "$id"
        return
    fi

    printf '%s' "$content" \
        | jq -cRs '{content: [{type: "text", text: .}], resultType: "complete"}' \
        | create_response "$id"
}

# ==== Message processing =================================================

# Parse one message with a single jq invocation (ADR-0004). Field order:
#   jsonrpc | id | method | protocolVersion | toolName | arguments
# `id` is empty when the key is absent, which is how a notification is
# distinguished from a request whose id is literally null.
parse_message() {
    jq -j '
        # Raw newlines would truncate the bash `read` below. Scalars are
        # squashed to spaces; the arguments blob is safe already because
        # tojson escapes newlines as the two characters \ and n.
        def str(v): (v // "") | tostring | gsub("[\n\r]"; " ");
        [ str(.jsonrpc),
          (if has("id") then (.id | tojson) else "" end),
          str(.method),
          str(.params?._meta?["io.modelcontextprotocol/protocolVersion"]?),
          str(.params?.name?),
          ((.params?.arguments? // {}) | tojson)
        ] | join("\u001f")
    ' 2>/dev/null
}

process_request() {
    local input="$1"
    local fields jsonrpc id method protocol_version tool_name arguments

    # A blank line is not a message.
    [[ -z "${input//[[:space:]]/}" ]] && return 0

    log "REQUEST" "$input"

    if ! fields=$(parse_message <<<"$input"); then
        create_error_response "null" -32700 "Parse error: input is not valid JSON"
        return
    fi

    IFS="$MCP_FS" read -r jsonrpc id method protocol_version tool_name arguments <<<"$fields"

    # No id means a notification: fire-and-forget, never answered - not even
    # to report that it was malformed.
    if [[ -z "$id" ]]; then
        log "INFO" "Notification received: ${method:-<none>}"
        return 0
    fi

    log "INFO" "Processing method: $method (id: $id, protocolVersion: ${protocol_version:-<none>})"

    if [[ "$jsonrpc" != "2.0" ]]; then
        create_error_response "$id" -32600 "Invalid Request: Not a JSON-RPC 2.0 request"
        return
    fi

    # server/discover is how a client learns which versions exist, so gating it
    # on the version would deadlock negotiation.
    if [[ "$method" == "server/discover" ]]; then
        handle_discover "$id"
        return
    fi

    if [[ "$protocol_version" != "$MCP_PROTOCOL_VERSION" ]]; then
        create_error_response "$id" -32022 \
            "Unsupported protocol version: ${protocol_version:-<missing>}" \
            "$(jq -cn --arg requested "$protocol_version" --arg supported "$MCP_PROTOCOL_VERSION" \
                '{requested: $requested, supported: [$supported]}')"
        return
    fi

    case "$method" in
    "tools/list")
        handle_tools_list "$id"
        ;;
    "tools/call")
        handle_tools_call "$id" "$tool_name" "$arguments"
        ;;
    *)
        create_error_response "$id" -32601 "Method not found: $method"
        ;;
    esac
}

# === Error codes ==========================================================
#
# JSON-RPC standard:
#   -32700  Parse error        - input was not valid JSON
#   -32600  Invalid Request    - not a JSON-RPC 2.0 message, or a bad tool name
#   -32601  Method not found
#   -32602  Invalid params     - includes "tool not found" and, per this
#                                revision, "resource not found" (moved from -32002)
#   -32603  Internal error     - server-side failure, e.g. unreadable config
#
# Allocation policy (2026-07-28):
#   -32000..-32019  implementation-defined; existing SDK usage grandfathered
#   -32020..-32099  reserved for the specification:
#       -32020  HeaderMismatch                   (HTTP transport only)
#       -32021  MissingRequiredClientCapability
#       -32022  UnsupportedProtocolVersion       - data: {requested, supported[]}
#
# Tool-level failures are NOT protocol errors: they come back as a successful
# result with isError=true so the model can see and correct them (ADR-0005).

# ==== Main loop ===========================================================
run_mcp_server() {
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed. Install it using: brew install jq" >&2
        exit 1
    fi

    log "INFO" "MCP server started (protocol $MCP_PROTOCOL_VERSION, stdio transport)"

    local line response
    while IFS= read -r line || [[ -n "$line" ]]; do
        response=$(process_request "$line")
        [[ -n "$response" ]] && echo "$response"
    done

    log "INFO" "stdin closed; exiting"
}
