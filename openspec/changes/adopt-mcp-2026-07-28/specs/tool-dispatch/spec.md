## ADDED Requirements

### Requirement: Tools are shell functions
A tool named `X` SHALL be implemented as a shell function `tool_X` that receives the
call arguments as a single JSON string in `$1`.

#### Scenario: Declared tool is callable
- **WHEN** `tools/call` names a tool whose `tool_<name>` function is defined
- **THEN** the function is invoked with the `arguments` object as its first parameter

#### Scenario: Absent arguments
- **WHEN** `tools/call` omits `arguments`
- **THEN** the function receives `{}`

### Requirement: Tool name validation
The server SHALL validate a tool name before dispatch and SHALL NOT allow a call to
resolve to an arbitrary shell function.

#### Scenario: Illegal characters
- **WHEN** a tool name contains anything outside `[a-zA-Z0-9_]`
- **THEN** the server responds with error code `-32600` and does not execute anything

#### Scenario: Unknown tool
- **WHEN** a well-formed tool name has no matching `tool_<name>` function
- **THEN** the server responds with error code `-32602`

### Requirement: Tool success is a content result
A tool that exits zero SHALL produce a successful `CallToolResult`.

#### Scenario: Successful call
- **WHEN** `tool_<name>` writes output and returns 0
- **THEN** the result contains a `content` array whose first element is
  `{"type":"text","text":<output>}`, `resultType: "complete"`, and no `isError: true`

### Requirement: Tool failure is reported to the model, not the transport
A tool that exits non-zero SHALL produce a successful JSON-RPC response carrying
`isError: true`, so the calling model can see the failure and self-correct.

#### Scenario: Validation failure
- **WHEN** `tool_<name>` writes an explanatory message and returns 1
- **THEN** the response is a JSON-RPC result — not a JSON-RPC error — with
  `isError: true` and the message as its text content

#### Scenario: Silent failure
- **WHEN** `tool_<name>` returns 1 without writing output
- **THEN** the result still carries `isError: true` with a generic failure message

### Requirement: Advertised tools are data
The tool list returned to clients SHALL come from the configured tools JSON file, and the
server SHALL NOT synthesise it from defined functions.

#### Scenario: Listing tools
- **WHEN** a client calls `tools/list`
- **THEN** the `tools` array is the content of `MCP_TOOLS_LIST_FILE`

#### Scenario: Advertised tool with no implementation
- **WHEN** the tools file advertises a tool that has no `tool_<name>` function and a
  client calls it
- **THEN** the server responds with error code `-32602` rather than executing anything
