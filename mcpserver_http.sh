#!/bin/bash
# mcpserver_http.sh - Streamable HTTP transport for MCP 2026-07-28 (ADR-0006).
#
# This is a TRANSPORT, not a second server: it maps HTTP onto the very same
# process_request() that the stdio binding uses, so protocol behaviour cannot
# drift between the two.
#
# Scope, honestly: a LOCAL, single-client endpoint. Binds 127.0.0.1, validates
# Origin, no TLS, no auth, one connection at a time on the nc backend. Put a
# real reverse proxy in front of it if it needs to leave the machine.
#
# Usage, from an implementation script that has already sourced the core:
#     source "$(dirname "${BASH_SOURCE[0]}")/mcpserver_http.sh"
#     run_mcp_http_server                 # PORT / BIND / MCP_ALLOWED_ORIGINS via env
#
# Portability rules this file obeys (spike 02): no `read -N` and no `declare -A`
# -- neither exists in bash 3.2, which is what /bin/bash is on macOS.

MCP_HTTP_PORT="${MCP_HTTP_PORT:-3000}"
MCP_HTTP_BIND="${MCP_HTTP_BIND:-127.0.0.1}"
MCP_HTTP_PATH="${MCP_HTTP_PATH:-/mcp}"
# Comma-separated allowlist. Requests carrying any other Origin get 403.
MCP_ALLOWED_ORIGINS="${MCP_ALLOWED_ORIGINS:-http://localhost,http://127.0.0.1}"

# ==== HTTP plumbing =======================================================

http_write() { # http_write <status-line> <content-type> <body>
    local status="$1" ctype="$2" body="$3"
    printf 'HTTP/1.1 %s\r\n' "$status"
    printf 'Content-Type: %s\r\n' "$ctype"
    printf 'Content-Length: %d\r\n' "${#body}"
    printf 'Connection: close\r\n'
    printf 'X-Accel-Buffering: no\r\n'
    printf '\r\n%s' "$body"
}

http_json() { # http_json <status-line> <json-body>
    http_write "$1" "application/json" "$2"
}

http_empty() { # http_empty <status-line>
    printf 'HTTP/1.1 %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' "$1"
}

# A JSON-RPC error carried in an HTTP error response.
http_rpc_error() { # http_rpc_error <status-line> <id-json> <code> <message> [data-json]
    http_json "$1" "$(create_error_response "$2" "$3" "$4" "${5:-null}")"
}

# Decode the spec's header sentinel: =?base64?<b64>?= wraps any value that is
# not safe as plain ASCII in a header. Plain values pass through untouched.
mcp_header_decode() {
    local value="$1"
    case "$value" in
    '=?base64?'*'?=')
        local inner="${value#=?base64?}"
        inner="${inner%\?=}"
        # -d covers GNU, busybox and modern macOS; -D is the older BSD spelling.
        printf '%s' "$inner" | base64 -d 2>/dev/null \
            || printf '%s' "$inner" | base64 -D 2>/dev/null
        ;;
    *)
        printf '%s' "$value"
        ;;
    esac
}

# ==== Request handling ====================================================

# Reads one HTTP request from stdin and writes one HTTP response to stdout.
handle_http_request() {
    local request_line method target line lower name value body
    local h_origin="" h_ctype="" h_protocol="" h_method="" h_name="" content_length=0
    local body_method body_name body_id body_protocol

    IFS= read -r request_line || return 0
    request_line="${request_line%$'\r'}"
    [[ -z "$request_line" ]] && return 0
    method="${request_line%% *}"
    target="${request_line#* }"; target="${target%% *}"

    # Header table without `declare -A` (bash 3.2 has no associative arrays).
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && break
        name="${line%%:*}"
        value="${line#*:}"
        value="${value# }"
        lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
        case "$lower" in
        origin) h_origin="$value" ;;
        content-type) h_ctype="$value" ;;
        content-length) content_length="$value" ;;
        mcp-protocol-version) h_protocol="$value" ;;
        mcp-method) h_method="$value" ;;
        mcp-name) h_name="$value" ;;
        # Ignored on purpose: this revision has no sessions and no resumable
        # streams, so an older client's headers are silently dropped.
        mcp-session-id | last-event-id) ;;
        esac
    done

    log "HTTP" "$method $target (origin: ${h_origin:-none}, mcp-method: ${h_method:-none})"

    # --- DNS-rebinding protection -----------------------------------------
    # An absent Origin is a non-browser client and is allowed; a present one
    # must be on the allowlist.
    if [[ -n "$h_origin" ]] && ! mcp_origin_allowed "$h_origin"; then
        log "ERROR" "Rejected origin: $h_origin"
        http_rpc_error "403 Forbidden" "null" -32600 "Origin not allowed: $h_origin"
        return 0
    fi

    # --- Method and path --------------------------------------------------
    # GET and DELETE were the old session/SSE endpoints; this revision has
    # neither, and the spec says to answer 405.
    case "$method" in
    POST) ;;
    GET | DELETE)
        log "INFO" "$method is not supported in this revision (no GET stream, no sessions)"
        http_empty "405 Method Not Allowed"
        return 0
        ;;
    *)
        http_empty "405 Method Not Allowed"
        return 0
        ;;
    esac

    if [[ "$target" != "$MCP_HTTP_PATH" && "$target" != "$MCP_HTTP_PATH"\?* ]]; then
        http_rpc_error "404 Not Found" "null" -32601 "No MCP endpoint at $target"
        return 0
    fi

    # --- Body -------------------------------------------------------------
    # `head -c` rather than `read -N`: -N does not exist in bash 3.2.
    if [[ "$content_length" -gt 0 ]]; then
        body=$(head -c "$content_length")
    else
        body=""
    fi

    if [[ -z "$body" ]]; then
        http_rpc_error "400 Bad Request" "null" -32700 "Empty request body"
        return 0
    fi

    if ! jq -e . >/dev/null 2>&1 <<<"$body"; then
        http_rpc_error "400 Bad Request" "null" -32700 "Parse error: body is not valid JSON"
        return 0
    fi

    body_id=$(jq -c 'if has("id") then .id else null end' <<<"$body")
    body_method=$(jq -r '.method // ""' <<<"$body")
    body_name=$(jq -r '.params.name // .params.uri // ""' <<<"$body")
    body_protocol=$(jq -r '.params._meta["io.modelcontextprotocol/protocolVersion"] // ""' <<<"$body")

    # --- Notifications ----------------------------------------------------
    # A message with no id is fire-and-forget: 202 with no body. Header
    # requirements are not defined for notification POSTs in this revision.
    if [[ "$(jq -c 'has("id")' <<<"$body")" == "false" ]]; then
        process_request "$body" >/dev/null
        http_empty "202 Accepted"
        return 0
    fi

    # --- Header/body validation (-32020) ----------------------------------
    # The point is not pedantry: an intermediary may route on the header while
    # the server executes the body, so a mismatch is a security bug.
    local mismatch=""
    if [[ -z "$h_protocol" ]]; then
        mismatch="Missing required header: MCP-Protocol-Version"
    elif [[ "$h_protocol" != "$body_protocol" ]]; then
        mismatch="MCP-Protocol-Version header '$h_protocol' does not match body value '$body_protocol'"
    elif [[ -z "$h_method" ]]; then
        mismatch="Missing required header: Mcp-Method"
    elif [[ "$h_method" != "$body_method" ]]; then
        mismatch="Mcp-Method header '$h_method' does not match body value '$body_method'"
    else
        case "$body_method" in
        tools/call | resources/read | prompts/get)
            local decoded_name
            decoded_name=$(mcp_header_decode "$h_name")
            if [[ -z "$h_name" ]]; then
                mismatch="Missing required header: Mcp-Name"
            elif [[ "$decoded_name" != "$body_name" ]]; then
                mismatch="Mcp-Name header '$decoded_name' does not match body value '$body_name'"
            fi
            ;;
        esac
    fi

    if [[ -n "$mismatch" ]]; then
        log "ERROR" "Header mismatch: $mismatch"
        http_rpc_error "400 Bad Request" "$body_id" -32020 "Header mismatch: $mismatch"
        return 0
    fi

    # --- Dispatch ---------------------------------------------------------
    # Identical semantics to stdio: the core owns the protocol.
    local response
    response=$(process_request "$body")

    if [[ -z "$response" ]]; then
        http_empty "202 Accepted"
        return 0
    fi

    # Status codes the transport binding prescribes for particular errors.
    local code
    code=$(jq -r '.error.code // ""' <<<"$response")
    case "$code" in
    -32022) http_json "400 Bad Request" "$response" ;;   # UnsupportedProtocolVersion
    -32020) http_json "400 Bad Request" "$response" ;;   # HeaderMismatch
    -32601) http_json "404 Not Found" "$response" ;;     # method not implemented
    -32700 | -32600) http_json "400 Bad Request" "$response" ;;
    *) http_json "200 OK" "$response" ;;
    esac
}

mcp_origin_allowed() {
    local origin="$1" allowed
    local saved_ifs="$IFS"
    IFS=','
    for allowed in $MCP_ALLOWED_ORIGINS; do
        allowed="${allowed# }"; allowed="${allowed% }"
        # A bare host entry matches any port on that host.
        if [[ "$origin" == "$allowed" || "$origin" == "$allowed":* ]]; then
            IFS="$saved_ifs"; return 0
        fi
    done
    IFS="$saved_ifs"
    return 1
}

# ==== Listener ============================================================

# Chosen at startup and logged: socat forks per connection, nc does not.
mcp_http_backend() {
    if command -v socat >/dev/null 2>&1; then echo "socat"
    elif command -v ncat >/dev/null 2>&1; then echo "ncat"
    elif command -v nc >/dev/null 2>&1; then echo "nc"
    else echo "none"; fi
}

# `nc -l <port>` is not universal. BSD/macOS and OpenBSD netcat accept it;
# netcat-traditional and busybox require `-l -p <port>` and error out otherwise.
# Rather than sniff version strings, bind a scratch port and see which spelling
# actually works on this machine.
mcp_nc_listen_flag() {
    local probe_port=$((20000 + RANDOM % 20000))
    local pid

    nc -l "$probe_port" >/dev/null 2>&1 &
    pid=$!
    sleep 0.3
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        echo "plain"          # nc -l PORT
        return 0
    fi

    nc -l -p "$probe_port" >/dev/null 2>&1 &
    pid=$!
    sleep 0.3
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        echo "dash_p"         # nc -l -p PORT
        return 0
    fi

    # Neither spelling stayed up. Assume the common one and let the failure be
    # visible rather than guessing further.
    echo "plain"
}

# Tear down the accept loop and everything it spawned. Idempotent, and safe to
# call from a trap.
mcp_http_shutdown() {
    trap - INT TERM EXIT
    # The accept pipeline is a background child; kill it and everything under
    # it, or `nc` survives, keeps the port, and outlives the server.
    if [[ -n "${MCP_HTTP_CHILD:-}" ]]; then
        pkill -P "$MCP_HTTP_CHILD" >/dev/null 2>&1
        kill "$MCP_HTTP_CHILD" >/dev/null 2>&1
    fi
    pkill -P $$ >/dev/null 2>&1
    [[ -n "${MCP_HTTP_FIFO:-}" ]] && rm -f "$MCP_HTTP_FIFO"
    log "INFO" "HTTP server stopped"
    exit 0
}

run_mcp_http_server() {
    # socat/ncat re-exec this same script per connection to handle one
    # request; that re-entry lands here first.
    if [[ "${1:-}" == "handle-connection" ]]; then
        handle_http_request
        return 0
    fi

    local backend self
    backend=$(mcp_http_backend)
    # Absolute path, because socat EXEC does not inherit the working directory
    # in any way worth relying on.
    self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    MCP_HTTP_SELF="${MCP_HTTP_SELF:-$self}"

    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required but not installed." >&2
        exit 1
    fi
    if [[ "$backend" == "none" ]]; then
        echo "Error: no listener available. Install socat (preferred) or netcat." >&2
        exit 1
    fi

    log "INFO" "MCP HTTP server on http://$MCP_HTTP_BIND:$MCP_HTTP_PORT$MCP_HTTP_PATH (backend: $backend, protocol: $MCP_PROTOCOL_VERSION)"
    echo "MCP server listening on http://$MCP_HTTP_BIND:$MCP_HTTP_PORT$MCP_HTTP_PATH" >&2
    echo "  transport: Streamable HTTP ($MCP_PROTOCOL_VERSION)  backend: $backend" >&2
    [[ "$backend" != "socat" ]] && echo "  note: $backend serves one connection at a time; install socat for concurrency" >&2

    case "$backend" in
    socat)
        # socat forks a handler per connection, so this is the only backend
        # that survives overlapping clients.
        export MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE MCP_LOG_FILE
        socat TCP-LISTEN:"$MCP_HTTP_PORT",bind="$MCP_HTTP_BIND",reuseaddr,fork \
            EXEC:"$MCP_HTTP_SELF handle-connection",nofork 2>>"$MCP_LOG_FILE"
        ;;
    ncat)
        ncat --listen "$MCP_HTTP_BIND" "$MCP_HTTP_PORT" --keep-open \
            --sh-exec "$MCP_HTTP_SELF handle-connection" 2>>"$MCP_LOG_FILE"
        ;;
    nc)
        # BSD nc has no -e and no --keep-open: re-arm the listener around a
        # FIFO, one connection at a time. There is a window between
        # connections where the port is refused (spike 02).
        local fifo flavour
        fifo=$(mktemp -u)
        mkfifo "$fifo"

        # Killing this process is not enough: the accept loop runs as a
        # pipeline, so `nc` and the pipeline subshell are separate children that
        # would otherwise be orphaned and keep holding the port. Reap them
        # explicitly. (On macOS the leftovers happened to die with the terminal;
        # on Linux they survive and hang whatever is waiting on the server.)
        MCP_HTTP_FIFO="$fifo"
        trap 'mcp_http_shutdown' INT TERM EXIT

        flavour=$(mcp_nc_listen_flag)
        log "INFO" "netcat listen syntax: $flavour"

        while true; do
            # nc's stdout is the client's request -> handler stdin.
            # Handler stdout -> fifo -> nc's stdin -> back to the client.
            #
            # The pipeline runs in the BACKGROUND and we `wait` on it, rather
            # than running it in the foreground. bash defers trap handling until
            # the current foreground command finishes, and `nc` blocks until a
            # client connects -- so a foreground pipeline leaves SIGTERM pending
            # forever and the server cannot be stopped. `wait` is interruptible,
            # so the trap fires immediately.
            if [[ "$flavour" == "dash_p" ]]; then
                { nc -l -p "$MCP_HTTP_PORT" <"$fifo" | handle_http_request >"$fifo"; } &
            else
                { nc -l "$MCP_HTTP_PORT" <"$fifo" | handle_http_request >"$fifo"; } &
            fi
            MCP_HTTP_CHILD=$!
            wait "$MCP_HTTP_CHILD"
        done
        ;;
    esac
}
