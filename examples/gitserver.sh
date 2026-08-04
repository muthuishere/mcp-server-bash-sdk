#!/bin/bash
# gitserver.sh - a worked example: expose a git repository to an AI agent.
#
# This is the SDK's second server, written to show the whole pattern on
# something real rather than canned data. It runs over BOTH transports:
#
#     ./examples/gitserver.sh                  # stdio (what an editor launches)
#     ./examples/gitserver.sh --http           # Streamable HTTP on :3000
#     MCP_HTTP_PORT=8080 ./examples/gitserver.sh --http
#
# Point it at any repo with GIT_REPO_PATH; it defaults to the current one.

SDK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Configuration paths MUST be set before the core is sourced -- it reads them
# at source time.
MCP_CONFIG_FILE="$SDK_DIR/examples/assets/gitserver_config.json"
MCP_TOOLS_LIST_FILE="$SDK_DIR/examples/assets/gitserver_tools.json"
MCP_LOG_FILE="$SDK_DIR/logs/gitserver.log"

source "$SDK_DIR/mcpserver_core.sh"
source "$SDK_DIR/mcpserver_http.sh"

# The repository this server talks about. Read from the environment so one
# script can serve any checkout.
GIT_REPO_PATH="${GIT_REPO_PATH:-$SDK_DIR}"

# --- helpers --------------------------------------------------------------

# Every tool runs git through this, so the repo check and the -C live in one
# place. Note that nothing here echoes to stdout on the success path except
# the payload itself: stdout is the protocol channel on stdio.
git_in_repo() {
    git -C "$GIT_REPO_PATH" "$@" 2>&1
}

repo_is_valid() {
    git -C "$GIT_REPO_PATH" rev-parse --git-dir >/dev/null 2>&1
}

# --- tools ----------------------------------------------------------------
#
# Contract (see readme): $1 is the arguments JSON. Echo the payload and
# return 0 on success. On failure, echo WHY and return 1 -- that reaches the
# model as isError=true so it can correct itself, rather than surfacing to the
# user as a transport fault.

# Tool: current status of the working tree.
tool_git_status() {
    if ! repo_is_valid; then
        echo "Not a git repository: $GIT_REPO_PATH"
        return 1
    fi

    local branch dirty
    branch=$(git_in_repo rev-parse --abbrev-ref HEAD)
    dirty=$(git_in_repo status --porcelain)

    jq -cn \
        --arg repo "$GIT_REPO_PATH" \
        --arg branch "$branch" \
        --arg dirty "$dirty" '
        {
          repository: $repo,
          branch: $branch,
          clean: ($dirty | length == 0),
          changes: ($dirty | split("\n") | map(select(length > 0))
                    | map({status: .[0:2] | ltrimstr(" "), path: .[3:]}))
        }'
    return 0
}

# Tool: recent commits, optionally filtered by author or path.
tool_git_log() {
    local args="$1"
    local limit author path_filter

    limit=$(jq -r '.limit // 10' <<<"$args")
    author=$(jq -r '.author // ""' <<<"$args")
    path_filter=$(jq -r '.path // ""' <<<"$args")

    if ! repo_is_valid; then
        echo "Not a git repository: $GIT_REPO_PATH"
        return 1
    fi
    # Validate before shelling out -- an unchecked value here would be an
    # argument injection into git.
    if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -lt 1 || "$limit" -gt 100 ]]; then
        echo "Invalid limit: must be a whole number between 1 and 100 (got '$limit')"
        return 1
    fi

    local -a git_args
    git_args=(log "-$limit" --pretty=format:'%H%x1f%an%x1f%aI%x1f%s')
    [[ -n "$author" ]] && git_args+=(--author="$author")
    [[ -n "$path_filter" ]] && git_args+=(-- "$path_filter")

    local raw
    raw=$(git_in_repo "${git_args[@]}")
    if [[ $? -ne 0 ]]; then
        echo "git log failed: $raw"
        return 1
    fi
    if [[ -z "$raw" ]]; then
        echo "No commits matched."
        return 0
    fi

    jq -cRn --arg raw "$raw" '
        $raw | split("\n") | map(select(length > 0)) | map(
          split("\u001f") | {sha: .[0][0:12], author: .[1], date: .[2], subject: .[3]})'
    return 0
}

# Tool: show what changed in one commit.
tool_git_show() {
    local args="$1"
    local ref stat

    ref=$(jq -r '.ref // ""' <<<"$args")

    if [[ -z "$ref" ]]; then
        echo "Missing required parameter: ref"
        return 1
    fi
    # A ref goes straight into a git command, so constrain it hard: no spaces,
    # no dashes at the start, no shell metacharacters.
    if ! [[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/~^-]*$ ]]; then
        echo "Invalid ref '$ref': expected a commit-ish like 'HEAD', 'main', or a SHA"
        return 1
    fi
    if ! repo_is_valid; then
        echo "Not a git repository: $GIT_REPO_PATH"
        return 1
    fi
    if ! git -C "$GIT_REPO_PATH" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
        echo "No such commit: $ref"
        return 1
    fi

    stat=$(git_in_repo show --stat --format='%H%n%an%n%aI%n%s%n%b' "$ref")
    # Multi-line output is fine now: the core escapes newlines into the JSON
    # string rather than flattening them.
    echo "$stat"
    return 0
}

# --- entry point ----------------------------------------------------------

case "${1:-}" in
--http)
    shift
    run_mcp_http_server "$@"
    ;;
handle-connection)
    # socat/ncat re-exec this script once per connection.
    run_mcp_http_server handle-connection
    ;;
*)
    run_mcp_server "$@"
    ;;
esac
