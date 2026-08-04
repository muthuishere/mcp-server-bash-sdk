# 🐚 MCP Server in Bash

[![MCP](https://img.shields.io/badge/MCP-2026--07--28-blue)](https://modelcontextprotocol.io/specification/2026-07-28)
[![Release](https://img.shields.io/github/v/release/muthuishere/mcp-server-bash-sdk?color=success)](https://github.com/muthuishere/mcp-server-bash-sdk/releases)
[![Platforms](https://img.shields.io/badge/tested-macOS%20%7C%20Debian%20%7C%20Alpine%20%7C%20Ubuntu-informational)](#supported-platforms)
[![License](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)
[![Discord](https://img.shields.io/badge/AgentNexus-join%20the%20community-5865F2?logo=discord&logoColor=white)](https://discord.gg/V9C2kvHC8D)

A lightweight, zero-overhead implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server in pure Bash — targeting the current **2026-07-28** revision.

📖 **[Documentation site](https://muthuishere.github.io/mcp-server-bash-sdk/)** · 🧩 **[Examples](examples/)** · 🧠 **[Architecture decisions](docs/adr/)** · 🔬 **[Spikes](docs/spikes/)**

**Why?** Most MCP servers are just API wrappers with schema conversion. This implementation provides a zero-overhead alternative to Node.js, Python, or other heavy runtimes.

**Why now?** The 2026-07-28 revision made MCP *stateless*: no `initialize` handshake, no sessions, no server-initiated requests. One line in, one line out — which is exactly the shape of a shell read loop. Bash went from an awkward fit to a natural one.

---

## 📋 Features

* ✅ MCP **2026-07-28** — stateless, per-request version negotiation
* ✅ **Both standard transports**: stdio and Streamable HTTP, from the same server file
* ✅ `server/discover`, `tools/list`, `tools/call`
* ✅ Dynamic tool discovery via function naming convention
* ✅ External configuration via JSON files
* ✅ Output validated against the official published JSON Schema

---

## 🔧 Requirements

- Bash 3.2 or newer (3.2 is what macOS ships as `/bin/bash`)
- `jq` for JSON processing (`brew install jq` / `apt install jq` / `apk add jq`)
- *(HTTP transport only)* `socat` preferred, or `netcat` — see the note under [Transports](#-transports)
- *(optional)* Python with `jsonschema`, only to run the schema conformance test

### Supported platforms

Verified by running the real test suites on each, not by inspection —
`./scripts/test-linux.sh all` reproduces the Linux rows on any machine with Docker.

| Platform | Shell | Unit | HTTP |
| --- | --- | --- | --- |
| macOS | bash 3.2 (`/bin/bash`) and 5.x | 31/31 | 19/19 |
| Debian / Ubuntu | bash 5.2 | 31/31 | 19/19 |
| Alpine (musl + busybox) | bash 5.3 | 31/31 | 19/19 |

Docker is needed only to verify *other* platforms — never to run a server.

---

## 🚀 Quick Start

1. **Clone the repo**

```bash
git clone https://github.com/muthuishere/mcp-server-bash-sdk
cd mcp-server-bash-sdk
```

2. **Make scripts executable**

```bash
chmod +x mcpserver_core.sh moviemcpserver.sh
```

3. **Try it out** — every request carries its protocol version in `params._meta`:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' | ./moviemcpserver.sh

echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_movies","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' | ./moviemcpserver.sh
```

4. **Or run it as a local HTTP endpoint**

```bash
./moviemcpserver.sh --http        # http://127.0.0.1:3000/mcp
```

5. **Run the tests**

```bash
./test_mcpserver_core.sh                          # 31 unit tests
./test_mcpserver_core.sh test_discover_shape      # a single test
./test_conformance.sh                             # validate against the official schema
./test_http_transport.sh                          # 19 HTTP transport tests
./scripts/test-linux.sh all                       # run everything on Debian, Alpine and Ubuntu
```

---

## 🏗️ Architecture

```
┌─────────────┐   stdio   ┌──────────────────────────────────────┐
│  MCP Host   │◄─────────►│  Your server (moviemcpserver.sh)     │
│ (AI System) │           │                                      │
│             │   HTTP    │  ┌────────────────────────────────┐  │
│             │◄─────────►│  │ Transport                      │  │
└─────────────┘           │  │  run_mcp_server (stdio)        │  │
                          │  │  mcpserver_http.sh (--http)    │  │
                          │  └───────────────┬────────────────┘  │
                          │                  ▼                   │
                          │  ┌────────────────────────────────┐  │
                          │  │ Protocol  mcpserver_core.sh    │  │
                          │  │   process_request()            │  │
                          │  └───────────────┬────────────────┘  │
                          │                  ▼                   │
                          │  ┌────────────────────────────────┐  │
                          │  │ Business logic  tool_* funcs   │  │
                          │  └───────────────┬────────────────┘  │
                          └──────────────────┼──────────────────-┘
                                             ▼
                              ┌──────────────────────────────┐
                              │ Config JSON · external APIs  │
                              └──────────────────────────────┘
```

Both transports call the **same** `process_request`, so they cannot drift in protocol behaviour.

- **mcpserver_core.sh**: JSON-RPC framing, MCP dispatch, version negotiation, result envelopes
- **mcpserver_http.sh**: the Streamable HTTP binding — headers, status codes, `Origin`, listener
- **moviemcpserver.sh** / **examples/gitserver.sh**: business logic — your `tool_*` functions
- **assets/**: discovery document and tool list
- **spec/**: the vendored official schema the conformance test validates against
- **examples/**: [four runnable servers and a build-your-own walkthrough](examples/README.md)
- **docs/adr/**: why the SDK is shaped this way · **docs/spikes/**: the experiments behind those decisions

---

## 🔌 Creating Your Own MCP Server

### Tool Function Guidelines

1. **Naming Convention**: prefix every tool function with `tool_`, matching the name in your tools JSON
2. **Parameters**: each function takes a single parameter `$1` containing the arguments as JSON
3. **Success**: echo the result, `return 0`
4. **Failure**: echo an explanatory message, `return 1` — the caller receives a **successful** response with `isError: true`, so the model can read the reason and retry. Tool failures are not transport errors.
5. **Automatic Discovery**: tools are dispatched by function name; the tools JSON controls what clients are *told* exists

### Implementation Steps

1. **Create your business logic file (e.g., `weatherserver.sh`)**

```bash
#!/bin/bash
# Weather API implementation

# Override configuration paths BEFORE sourcing the core
MCP_CONFIG_FILE="$(dirname "${BASH_SOURCE[0]}")/assets/weatherserver_config.json"
MCP_TOOLS_LIST_FILE="$(dirname "${BASH_SOURCE[0]}")/assets/weatherserver_tools.json"
MCP_LOG_FILE="$(dirname "${BASH_SOURCE[0]}")/logs/weatherserver.log"

source "$(dirname "${BASH_SOURCE[0]}")/mcpserver_core.sh"

API_KEY="${MCP_API_KEY:-default_key}"

# Tool: Get current weather for a location
tool_get_weather() {
  local args="$1"
  local location=$(echo "$args" | jq -r '.location')

  if [[ -z "$location" || "$location" == "null" ]]; then
    echo "Missing required parameter: location"   # reaches the model as isError
    return 1
  fi

  curl -s "https://api.example.com/weather?location=$location&apikey=$API_KEY"
  return 0
}

# stdio by default; --http serves the same tools over Streamable HTTP.
case "${1:-}" in
  --http)            shift; run_mcp_http_server "$@" ;;
  handle-connection) run_mcp_http_server handle-connection ;;
  *)                 run_mcp_server "$@" ;;
esac
```

For the `--http` mode also `source "$(dirname "${BASH_SOURCE[0]}")/mcpserver_http.sh"` next to the core.

Four runnable examples are in **[examples/](examples/README.md)**, each covering a different problem:

| Example | What it shows |
| --- | --- |
| [`gitserver.sh`](examples/gitserver.sh) | Shelling out safely — argument validation, structured output |
| [`weatherserver.sh`](examples/weatherserver.sh) | Wrapping a third-party API — secrets in env, network failures, trimming the response |
| [`fileserver.sh`](examples/fileserver.sh) | Saying no — read-only filesystem access with a real path-traversal boundary |
| [`moviemcpserver.sh`](moviemcpserver.sh) | The minimum, over canned data |

2. **Create `assets/weatherserver_tools.json`**

```json
{
  "tools": [
    {
      "name": "get_weather",
      "description": "Get current weather for a location",
      "inputSchema": {
        "type": "object",
        "properties": {
          "location": {
            "type": "string",
            "description": "City name or coordinates"
          }
        },
        "required": ["location"]
      }
    }
  ]
}
```

Keep the array order stable — the spec asks servers to return tools deterministically so clients (and LLM prompt caches) can cache them.

3. **Create `assets/weatherserver_config.json`** — this is now the `server/discover` body, not an `initialize` result:

```json
{
  "supportedVersions": ["2026-07-28"],
  "serverInfo": {
    "name": "WeatherServer",
    "version": "1.0.0"
  },
  "capabilities": {
    "tools": {
      "listChanged": false
    }
  },
  "ttlMs": 3600000,
  "cacheScope": "public",
  "instructions": "This server provides weather information."
}
```

4. **Make your file executable**

```bash
chmod +x weatherserver.sh
```

---

## 🔀 Transports

Both are the spec's standard bindings, and both run from the same server file.

### stdio

What an editor or agent launches as a subprocess. This is the default and the one to use
unless you specifically need HTTP.

```bash
./moviemcpserver.sh
```

### Streamable HTTP

`2026-07-28` removed sessions, the GET stream and SSE resumability, so this binding is now
just *POST a message, get JSON back* — which is why it fits in a shell script at all.

```bash
./moviemcpserver.sh --http                    # http://127.0.0.1:3000/mcp
MCP_HTTP_PORT=8080 ./moviemcpserver.sh --http
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `MCP_HTTP_PORT` | `3000` | listening port |
| `MCP_HTTP_BIND` | `127.0.0.1` | interface — leave it on loopback |
| `MCP_HTTP_PATH` | `/mcp` | endpoint path |
| `MCP_ALLOWED_ORIGINS` | `http://localhost,http://127.0.0.1` | `Origin` allowlist; anything else gets `403` |

Every POST **must** carry `MCP-Protocol-Version` and `Mcp-Method`, plus `Mcp-Name` for
`tools/call` / `resources/read` / `prompts/get`, and each must match the request body —
a mismatch is `400` with `-32020`. That is a security control, not ceremony: an
intermediary may route on the header while the server executes the body.

> ⚠️ **This is a local endpoint, not a web server.** It binds loopback, has no TLS and no
> auth. Install `socat` (`brew install socat`) and it forks per connection; without it the
> `netcat` fallback serves **one connection at a time**, with a brief window between
> connections where the port is refused. To expose it beyond localhost, put a real reverse
> proxy in front. See [ADR-0006](docs/adr/0006-add-streamable-http.md) and
> [spike 02](docs/spikes/spike-02-http-listener.md).

---

## 🖥️ Using with an MCP client

```jsonc
"mcp": {
    "servers": {
        "my-weather-server": {
            "type": "stdio",
            "command": "/path/to/your/weatherserver.sh",
            "args": [],
            "env": {
                "MCP_API_KEY": "your-api-key"
            }
        }
    }
}
```

⚠️ **The client must speak MCP `2026-07-28`.** This SDK implements that revision only and rejects older ones with `-32022` ([ADR-0002](docs/adr/0002-target-2026-07-28-only.md) explains the trade-off). Editors still on `2025-06-18` / `2025-11-25` will need a shim until they upgrade.

---

## 🚫 Limitations

* **HTTP is a local endpoint**: no TLS, no auth, and without `socat` it serves one connection at a time
* **No SSE response mode**, so no `notifications/progress` streaming and no `subscriptions/listen`
* No concurrency on stdio: one client, one process, ~30 requests/second
* No resources, prompts, MRTR input requests, or the tasks extension
* Clients older than `2026-07-28` are rejected

For AI assistants and local tool execution, these aren't blocking issues.

---

## 🧭 Design notes

This SDK is documented as much by *why* as by *how*:

- **[Architecture decisions](docs/adr/)** — seven ADRs, each recording what was rejected and
  why. ADR-0001 chose stdio-only and is now superseded in scope by ADR-0006; the reversal is
  recorded rather than edited away, because the protocol changed underneath it.
- **[Spikes](docs/spikes/)** — runnable experiments behind every number here. They are how
  the two platform bugs were found: `read -N` missing from macOS's bash 3.2, and Linux
  capping a single `argv` entry at 128 KB where macOS does not.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

Blog : https://medium.com/@muthuishere/why-i-built-an-mcp-server-sdk-in-shell-yes-bash-6f2192072279

## Community

Questions, ideas, or built something with this? Join **[AgentNexus](https://discord.gg/V9C2kvHC8D)** — a Discord
for people building with AI agents and open tools. This project lives in **#mcp-bash-sdk**.
