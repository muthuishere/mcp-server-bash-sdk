# Examples

Four working servers, and a walkthrough of building your own. Each one is runnable and
covers a different problem you will actually hit.

| Example | What it shows |
| --- | --- |
| [`../moviemcpserver.sh`](../moviemcpserver.sh) | The minimum: three tools over canned data |
| [`gitserver.sh`](gitserver.sh) | Shelling out safely — `git` subcommands, argument validation, structured output |
| [`weatherserver.sh`](weatherserver.sh) | Wrapping a third-party HTTP API — secrets in env, network failures, trimming a fat response |
| [`fileserver.sh`](fileserver.sh) | Saying no — read-only filesystem access with a real path-traversal boundary |

All four run over **both** transports from a single file.

---

## Run them

```bash
# stdio — this is what an editor or agent launches as a subprocess
./examples/gitserver.sh

# Streamable HTTP — a local endpoint on 127.0.0.1:3000/mcp
./examples/gitserver.sh --http
MCP_HTTP_PORT=8080 GIT_REPO_PATH=~/some/other/repo ./examples/gitserver.sh --http

# the others take their configuration from the environment too
./examples/weatherserver.sh
FILE_ROOT=~/notes ./examples/fileserver.sh
```

Ask the git server what changed recently, over stdio:

```bash
META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"git_log","arguments":{"limit":3},'"$META"'}}' \
  | ./examples/gitserver.sh | jq -r '.result.content[0].text | fromjson'
```

The same call over HTTP — note the headers are **mandatory** and must match the body:

```bash
curl -s -X POST http://127.0.0.1:3000/mcp \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2026-07-28' \
  -H 'Mcp-Method: tools/call' \
  -H 'Mcp-Name: git_log' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"git_log","arguments":{"limit":3},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
  | jq -r '.result.content[0].text | fromjson'
```

Send `Mcp-Name: something_else` and you get `400` with `-32020`. That is the spec working:
an intermediary might route on the header while the server executes the body, so the two
are required to agree.

---

## Build your own, in four steps

### 1. Write the script

Three rules, and the order of the first one matters:

```bash
#!/bin/bash
SDK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# (1) Config paths BEFORE sourcing the core -- it reads them at source time.
MCP_CONFIG_FILE="$SDK_DIR/examples/assets/myserver_config.json"
MCP_TOOLS_LIST_FILE="$SDK_DIR/examples/assets/myserver_tools.json"
MCP_LOG_FILE="$SDK_DIR/logs/myserver.log"

source "$SDK_DIR/mcpserver_core.sh"
source "$SDK_DIR/mcpserver_http.sh"   # only if you want the --http mode

# (2) A tool named X is a function named tool_X taking arguments JSON in $1.
tool_greet() {
  local name
  name=$(jq -r '.name // ""' <<<"$1")

  if [[ -z "$name" ]]; then
    echo "Missing required parameter: name"   # the model sees this and can retry
    return 1
  fi

  echo "Hello, $name"
  return 0
}

# (3) Dispatch on the transport.
case "${1:-}" in
  --http)            shift; run_mcp_http_server "$@" ;;
  handle-connection) run_mcp_http_server handle-connection ;;
  *)                 run_mcp_server "$@" ;;
esac
```

### 2. Declare the tools

`assets/myserver_tools.json` is what clients are *told* exists. Nothing checks it against
your functions, so a typo here is a tool that lists but cannot be called.

```json
{
  "tools": [
    {
      "name": "greet",
      "description": "Greet someone by name.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Who to greet." }
        },
        "required": ["name"]
      }
    }
  ]
}
```

Keep the array order stable — the spec asks servers to return tools deterministically so
clients and LLM prompt caches can cache them.

### 3. Declare the server

`assets/myserver_config.json` is the `server/discover` response body. There is no
`initialize` in this revision; this is how a client learns who you are.

```json
{
  "supportedVersions": ["2026-07-28"],
  "serverInfo": { "name": "MyServer", "version": "1.0.0" },
  "capabilities": { "tools": { "listChanged": false } },
  "ttlMs": 60000,
  "cacheScope": "private",
  "instructions": "What this server is for, and how to use it well."
}
```

`instructions` goes into the model's context — spend a sentence on *when* to reach for
each tool, not on restating the schemas.

Use `"cacheScope": "private"` when results depend on who is asking or on mutable local
state (the git server does), `"public"` when they do not. `ttlMs` is how long a client may
reuse the tool list before re-fetching.

### 4. Make it executable, and try it

```bash
chmod +x examples/myserver.sh
echo '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
  | ./examples/myserver.sh | jq .
```

---

## What the git server is actually demonstrating

Read [`gitserver.sh`](gitserver.sh) alongside these — each is a decision you will face.

**Failure is a message to the model, not to the user.** Every tool returns 1 with a
sentence explaining what was wrong. The core turns that into a successful response
carrying `isError: true`, so the model reads "Invalid limit: must be a whole number
between 1 and 100" and retries with a valid one. Returning a protocol error instead would
surface a red error to the human and teach the model nothing
([ADR-0005](../docs/adr/0005-tool-errors-are-results.md)).

**Validate before you shell out.** `git_show` constrains `ref` to
`^[A-Za-z0-9][A-Za-z0-9._/~^-]*$` before it reaches a `git` command. The tool arguments
come from a language model reading untrusted content; an unchecked value here is an
argument injection. The same reasoning is why the core validates tool *names* against
`^[a-zA-Z0-9_]+$` before dispatch — otherwise `tools/call` could reach any shell function
in scope.

**stdout belongs to the protocol.** On stdio, a stray `echo` outside your tool's return
value corrupts the message stream. `git_in_repo` folds stderr into the captured output
rather than letting it leak. Use `log INFO "..."` for diagnostics — it goes to the log
file, never to stdout.

**Structured output is just text.** MCP gives you a `content` array of text blocks, so
"structured" means: emit compact JSON as the text and let the model parse it. `git_status`
builds its object with `jq -cn --arg`, never string concatenation — one embedded quote in
a branch name would otherwise produce malformed JSON.

**Multi-line output survives.** `git_show` echoes a multi-line diffstat directly. The core
escapes the newlines into the JSON string rather than flattening them, so formatting
reaches the model intact.

**Large output survives too — but keep it off `argv` in your own tools.** The core pipes
tool output to `jq` on stdin, so a 500 KB result round-trips on Linux as well as macOS. If
your tool builds JSON itself, do the same: Linux rejects any single command argument over
128 KB (`MAX_ARG_STRLEN`) while macOS does not, so `jq --arg blob "$big"` is a bug that only
appears in production ([ADR-0007](../docs/adr/0007-portability-is-tested.md)).

**Only `jq` is assumed.** `git_log` does its arithmetic and JSON in `jq` rather than
reaching for `bc` or `python`, because neither is present in a slim container image.

**One file, both transports.** The transport is a deployment choice, not a different
program. `--http` swaps the binding; the tools do not know or care which one is running.

---

## What the other two are demonstrating

### `weatherserver.sh` — wrapping someone else's API

Most MCP servers are API wrappers, and these are the parts that bite:

- **Secrets come from the environment, never the source.** `WEATHER_API_KEY` is read from
  the env and only expands at the point `curl` consumes it. wttr.in needs no key; the
  pattern is there because your API will.
- **Check the status code separately from the body.** `curl -o file -w '%{http_code}'`
  keeps them apart, so a `404` page is never mistaken for data.
- **Network failure is the common case, so say what happened.** "Could not reach the
  weather service (timeout after 10s)" lets the model retry or report; a silent empty
  result teaches it nothing.
- **Trim the response.** The upstream payload is hundreds of fields; the tool returns
  seven. Everything you pass through costs context on every call.

### `fileserver.sh` — the example that mostly says no

Tool arguments come from a model reading untrusted content, so "read a file" sits one
careless line away from reading `~/.ssh/id_rsa`.

**Resolve first, compare after.** Blocklisting `..` is the wrong instinct — it misses
symlinks, absolute paths and encoded traversal. `resolve_within_root` resolves the path
through the filesystem (`pwd -P`, following symlinks with a bounded loop) and only then
checks that the result is inside the root. The check is about where the path *lands*, not
how it was spelled. Verified against relative traversal, absolute paths, a symlink to
`/etc/passwd`, and a relative symlink escaping the tree — all refused.

Two smaller judgement calls worth copying: refuse binary files rather than mangling them
into a JSON string, and enforce a size limit *before* reading, so a huge file cannot blow
up the response.

---

## Wiring it into a client

```jsonc
"mcp": {
  "servers": {
    "git": {
      "type": "stdio",
      "command": "/absolute/path/to/examples/gitserver.sh",
      "args": [],
      "env": { "GIT_REPO_PATH": "/absolute/path/to/your/repo" }
    }
  }
}
```

⚠️ The client must speak MCP `2026-07-28`. This SDK implements that revision only and
rejects anything else with `-32022` — see
[ADR-0002](../docs/adr/0002-target-2026-07-28-only.md) for why that trade was made.
