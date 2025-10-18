# 🐚 MCP Server in Bash

A lightweight, zero-overhead implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server in pure Bash. 

**Why?** Most MCP servers are just API wrappers with schema conversion. This implementation provides a zero-overhead alternative to Node.js, Python, or other heavy runtimes.

---

## 📋 Features

* ✅ Full JSON-RPC 2.0 protocol over stdio
* ✅ Complete MCP protocol implementation
* ✅ Dynamic tool discovery via function naming convention
* ✅ External configuration via JSON files
* ✅ Easy to extend with custom tools

---

## 🔧 Requirements

- Bash shell
- `jq` for JSON processing (`brew install jq` on macOS)

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

3. **Try it out**

```bash
echo '{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "get_movies"}, "id": 1}' | ./moviemcpserver.sh
```

---

## 🏗️ Architecture

```
┌─────────────┐         ┌────────────────────────┐
│ MCP Host    │         │ MCP Server             │
│ (AI System) │◄──────► │ (moviemcpserver.sh)    │
└─────────────┘ stdio   └────────────────────────┘
                             │
                     ┌───────┴──────────┐
                     ▼                  ▼
            ┌───────────────────┐  ┌───────────────┐
            │ Protocol Layer    │  │ Business Logic│
            │(mcpserver_core.sh)│  │(tool_* funcs) │
            └───────────────────┘  └───────────────┘
                     │                  │
                     ▼                  ▼
              ┌─────────────────┐  ┌───────────────┐
              │ Configuration   │  │ External      │
              │ (JSON Files)    │  │ Services/APIs │
              └─────────────────┘  └───────────────┘
```

- **mcpserver_core.sh**: Handles JSON-RPC and MCP protocol
- **moviemcpserver.sh**: Contains business logic functions
- **assets/**: JSON configuration files

---

## 🔌 Creating Your Own MCP Server

### Tool Function Guidelines

When implementing tool functions for the MCP server, follow these guidelines:

1. **Naming Convention**: All tool functions must be prefixed with `tool_` followed by the same name defined in tools_list.json
2. **Parameters**: Each function should accept a single parameter `$1` containing JSON arguments
3. **Success Pattern**: For successful operations, echo the result and return 0
4. **Error Pattern**: For validation errors, echo an error message and return 1
5. **Automatic Discovery**: All tool functions are automatically exposed to the MCP server based on tools_list.json

### Implementation Steps

1. **Create your business logic file (e.g., `weatherserver.sh`)**

```bash
#!/bin/bash
# Weather API implementation

# Override configuration paths BEFORE sourcing the core
MCP_CONFIG_FILE="$(dirname "${BASH_SOURCE[0]}")/assets/weatherserver_config.json"
MCP_TOOLS_LIST_FILE="$(dirname "${BASH_SOURCE[0]}")/assets/weatherserver_tools.json"
MCP_LOG_FILE="$(dirname "${BASH_SOURCE[0]}")/logs/weatherserver.log"

# MCP Server Tool Function Guidelines:
# 1. Name all tool functions with prefix "tool_" followed by the same name defined in tools_list.json
# 2. Function should accept a single parameter "$1" containing JSON arguments
# 3. For successful operations: Echo the expected result and return 0
# 4. For errors: Echo an error message and return 1
# 5. All tool functions are automatically exposed to the MCP server based on tools_list.json

# Source the core MCP server implementation
source "$(dirname "${BASH_SOURCE[0]}")/mcpserver_core.sh"

# Access environment variables
API_KEY="${MCP_API_KEY:-default_key}"

# Tool: Get current weather for a location
# Parameters: Takes a JSON object with location
# Success: Echo JSON result and return 0
# Error: Echo error message and return 1
tool_get_weather() {
  local args="$1"
  local location=$(echo "$args" | jq -r '.location')
  
  # Parameter validation
  if [[ -z "$location" ]]; then
    echo "Missing required parameter: location"
    return 1
  fi
  
  # Call external API
  local weather=$(curl -s "https://api.example.com/weather?location=$location&apikey=$API_KEY")
  echo "$weather"
  return 0
}


# Start the MCP server
run_mcp_server "$@"
```

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

3. **Create `assets/weatherserver_config.json`**

```json
{
  "protocolVersion": "2025-03-26",
  "serverInfo": {
    "name": "WeatherServer",
    "version": "1.0.0"
  },
  "capabilities": {
    "tools": {
      "listChanged": true
    }
  },
  "instructions": "This server provides weather information."
}
```

4. **Make your file executable**

```bash
chmod +x weatherserver.sh
```

---

## 🖥️ Using with VS Code & GitHub Copilot

1. **Update VS Code settings.json**

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

2. **Use with GitHub Copilot Chat**

```
/mcp my-weather-server get weather for New York
```

---

## 🚫 Limitations

* No concurrency/parallel processing
* Limited memory management
* No streaming responses
* Not designed for high throughput

For AI assistants and local tool execution, these aren't blocking issues.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

Blog : https://medium.com/@muthuishere/why-i-built-an-mcp-server-sdk-in-shell-yes-bash-6f2192072279
