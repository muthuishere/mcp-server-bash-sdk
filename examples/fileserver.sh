#!/bin/bash
# fileserver.sh - a worked example: read-only access to one directory tree.
#
# The interesting part of this example is the part that says no. Tool arguments
# come from a model that is reading untrusted content, so "read a file" is one
# careless line away from "read /etc/passwd" or "read ~/.ssh/id_rsa".
#
#     FILE_ROOT=~/notes ./examples/fileserver.sh            # stdio
#     FILE_ROOT=~/notes ./examples/fileserver.sh --http     # HTTP on :3000
#
# FILE_ROOT defaults to the SDK directory. Everything below it is readable;
# nothing above it is, and that is enforced after symlink resolution, not by
# pattern-matching the input.

SDK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MCP_CONFIG_FILE="$SDK_DIR/examples/assets/fileserver_config.json"
MCP_TOOLS_LIST_FILE="$SDK_DIR/examples/assets/fileserver_tools.json"
MCP_LOG_FILE="$SDK_DIR/logs/fileserver.log"

source "$SDK_DIR/mcpserver_core.sh"
source "$SDK_DIR/mcpserver_http.sh"

FILE_ROOT="${FILE_ROOT:-$SDK_DIR}"
FILE_MAX_BYTES="${FILE_MAX_BYTES:-100000}"

# --- the security boundary ------------------------------------------------

# Resolve a path and prove it is inside FILE_ROOT. Echoes the resolved path on
# success; prints nothing and returns 1 otherwise.
#
# Blocklisting ".." is the wrong instinct: it misses symlinks, absolute paths,
# encoded traversal and "..." typos. Resolve first, compare after -- then the
# check is about where the path ACTUALLY lands, not how it was spelled.
resolve_within_root() {
    local requested="$1" root_real full dir base target hop

    [[ -z "$requested" ]] && return 1

    # `pwd -P` is the resolver: it expands symlinks and normalises `..`, using
    # the filesystem rather than string rules. `realpath`/`readlink -f` would be
    # tidier but neither is portable to macOS's BSD userland.
    root_real=$(cd "$FILE_ROOT" 2>/dev/null && pwd -P) || return 1

    case "$requested" in
    /*) full="$requested" ;;      # absolute paths are allowed, then checked
    *) full="$root_real/$requested" ;;
    esac

    # Follow symlinks by hand, bounded, so a symlink loop cannot hang the
    # server. Each hop re-resolves the parent, which is what catches a link
    # whose *directory* escapes the root.
    for hop in 1 2 3 4 5 6 7 8; do
        dir=$(cd "$(dirname "$full")" 2>/dev/null && pwd -P) || return 1
        base=$(basename "$full")
        full="$dir/$base"
        [[ -L "$full" ]] || break
        target=$(readlink "$full") || return 1
        case "$target" in
        /*) full="$target" ;;
        *) full="$dir/$target" ;;
        esac
    done

    # For a directory, resolve it directly so `a/../..` cannot survive.
    [[ -d "$full" ]] && full=$(cd "$full" 2>/dev/null && pwd -P)

    # The trailing slash matters: /srv/rootkit must not pass as /srv/root.
    [[ "$full" == "$root_real" || "$full" == "$root_real"/* ]] || return 1

    echo "$full"
}

# --- tools ----------------------------------------------------------------

# Tool: list entries in a directory under the root.
tool_list_files() {
    local args="$1"
    local requested resolved

    requested=$(jq -r '.path // "."' <<<"$args")

    if ! resolved=$(resolve_within_root "$requested"); then
        echo "Path '$requested' is outside the served directory or does not exist"
        return 1
    fi
    if [[ ! -d "$resolved" ]]; then
        echo "Not a directory: $requested"
        return 1
    fi

    # -A skips . and ..; the loop keeps names with spaces intact.
    local entries="[]" name kind size
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if [[ -d "$resolved/$name" ]]; then
            kind="directory"; size=0
        else
            kind="file"; size=$(wc -c <"$resolved/$name" 2>/dev/null | tr -d ' ')
        fi
        entries=$(jq -c --arg n "$name" --arg k "$kind" --argjson s "${size:-0}" \
            '. + [{name: $n, type: $k, bytes: $s}]' <<<"$entries")
    done < <(ls -A "$resolved" 2>/dev/null | sort)

    jq -cn --arg path "$requested" --argjson entries "$entries" \
        '{path: $path, entries: $entries, count: ($entries | length)}'
    return 0
}

# Tool: read a text file under the root.
tool_read_file() {
    local args="$1"
    local requested resolved size

    requested=$(jq -r '.path // ""' <<<"$args")

    if [[ -z "$requested" ]]; then
        echo "Missing required parameter: path"
        return 1
    fi
    if ! resolved=$(resolve_within_root "$requested"); then
        echo "Path '$requested' is outside the served directory or does not exist"
        return 1
    fi
    if [[ -d "$resolved" ]]; then
        echo "'$requested' is a directory. Use list_files instead."
        return 1
    fi
    if [[ ! -r "$resolved" ]]; then
        echo "Cannot read '$requested': no such file, or permission denied"
        return 1
    fi

    size=$(wc -c <"$resolved" | tr -d ' ')
    if [[ "$size" -gt "$FILE_MAX_BYTES" ]]; then
        echo "File is ${size} bytes, over the ${FILE_MAX_BYTES}-byte limit. Nothing was read."
        return 1
    fi

    # Binary content would corrupt the JSON string and waste the model's
    # context; refuse it rather than mangling it.
    if LC_ALL=C grep -qI . "$resolved" 2>/dev/null; then
        cat "$resolved"
        return 0
    fi
    echo "'$requested' looks like a binary file; this server only serves text."
    return 1
}

# --- entry point ----------------------------------------------------------

case "${1:-}" in
--http)
    shift
    run_mcp_http_server "$@"
    ;;
handle-connection)
    run_mcp_http_server handle-connection
    ;;
*)
    run_mcp_server "$@"
    ;;
esac
