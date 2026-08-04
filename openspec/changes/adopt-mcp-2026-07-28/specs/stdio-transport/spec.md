## ADDED Requirements

### Requirement: Newline-delimited framing
The server SHALL read one JSON-RPC message per line from stdin and SHALL write one
message per line to stdout.

#### Scenario: Sequential messages
- **WHEN** several messages arrive on consecutive lines
- **THEN** the server emits exactly one response line per request, in order

#### Scenario: Final line without trailing newline
- **WHEN** the last line of input has no trailing newline
- **THEN** the server still processes it

#### Scenario: Large payload
- **WHEN** a single request line is 4 MB long
- **THEN** the server reads it intact and responds without truncation

### Requirement: stdout carries protocol traffic only
The server SHALL NOT write anything to stdout that is not a valid MCP message.

#### Scenario: Every line is JSON
- **WHEN** any sequence of requests is processed
- **THEN** every non-empty stdout line parses as JSON

#### Scenario: Tool output with embedded newlines
- **WHEN** a tool emits multi-line output
- **THEN** the newlines are carried as escaped characters inside a single-line JSON
  string, preserving the content, and no raw newline reaches the protocol stream

### Requirement: Diagnostics go to a log file or stderr
The server SHALL route all diagnostic output away from stdout.

#### Scenario: Logging during a call
- **WHEN** the server logs a request, a response, or an error
- **THEN** the text appears in the configured log file and never on stdout

### Requirement: Shutdown on EOF
The server SHALL exit promptly when stdin reaches end-of-file.

#### Scenario: Client closes stdin
- **WHEN** the client closes the server's stdin
- **THEN** the server exits with status 0 without needing a signal

### Requirement: Configuration is resolved before dispatch
The server SHALL take its discovery document, tool list, and log destination from
overridable file paths.

#### Scenario: Implementation overrides paths
- **WHEN** an implementation script sets `MCP_CONFIG_FILE`, `MCP_TOOLS_LIST_FILE`, or
  `MCP_LOG_FILE` before sourcing the core
- **THEN** the core uses those paths

#### Scenario: Missing configuration file
- **WHEN** a configured JSON file does not exist
- **THEN** the server responds with a JSON-RPC error rather than emitting a malformed
  result
