## ADDED Requirements

### Requirement: Single POST endpoint
The server SHALL expose one HTTP endpoint that accepts POST, and SHALL reject other
methods and paths.

#### Scenario: POST to the MCP endpoint
- **WHEN** a client POSTs a JSON-RPC request to the configured endpoint path
- **THEN** the server responds with `Content-Type: application/json` and a single
  JSON-RPC message

#### Scenario: GET is refused
- **WHEN** a client issues GET to the endpoint
- **THEN** the server responds `405 Method Not Allowed`

#### Scenario: DELETE is refused
- **WHEN** a client issues DELETE to the endpoint
- **THEN** the server responds `405 Method Not Allowed`

#### Scenario: Unknown path
- **WHEN** a client POSTs to any other path
- **THEN** the server responds `404 Not Found` with a JSON-RPC error

### Requirement: Header and body must agree
The server SHALL require the revision's standard request headers and SHALL reject any
request whose header values disagree with the request body.

#### Scenario: Matching headers
- **WHEN** `MCP-Protocol-Version` and `Mcp-Method` match the body, and `Mcp-Name` matches
  `params.name` for a `tools/call`
- **THEN** the request is processed normally

#### Scenario: Missing protocol version header
- **WHEN** a request omits `MCP-Protocol-Version`
- **THEN** the server responds `400 Bad Request` with error code `-32020`

#### Scenario: Missing method header
- **WHEN** a request omits `Mcp-Method`
- **THEN** the server responds `400 Bad Request` with error code `-32020`

#### Scenario: Name header disagrees with body
- **WHEN** a `tools/call` request carries an `Mcp-Name` that differs from `params.name`
- **THEN** the server responds `400 Bad Request` with error code `-32020` and does not
  execute the tool

#### Scenario: Version header disagrees with body
- **WHEN** `MCP-Protocol-Version` differs from the protocol version in the body `_meta`
- **THEN** the server responds `400 Bad Request` with error code `-32020`, distinguishing
  a header mismatch from an unsupported version

#### Scenario: Base64 sentinel header value
- **WHEN** `Mcp-Name` is supplied in the `=?base64?<encoded>?=` form
- **THEN** the server decodes it before comparing it to the body value, and accepts a
  matching request

### Requirement: Protocol errors map onto HTTP statuses
The server SHALL return the HTTP status the transport binding prescribes for each class of
protocol error.

#### Scenario: Unsupported protocol version
- **WHEN** the request declares a protocol version the server does not implement, in both
  header and body
- **THEN** the server responds `400 Bad Request` with error code `-32022` and a
  `data.supported` list

#### Scenario: Unknown method
- **WHEN** the request names a method the server does not implement
- **THEN** the server responds `404 Not Found` with error code `-32601`

#### Scenario: Malformed body
- **WHEN** the request body is not valid JSON
- **THEN** the server responds `400 Bad Request` with error code `-32700`

#### Scenario: Successful call
- **WHEN** a request is processed successfully, including a tool that failed and returned
  `isError`
- **THEN** the server responds `200 OK`

### Requirement: Notifications are accepted without a response
The server SHALL acknowledge a JSON-RPC notification without returning a message body.

#### Scenario: Cancellation notification over HTTP
- **WHEN** a client POSTs a message with no `id`
- **THEN** the server responds `202 Accepted` with an empty body

### Requirement: DNS-rebinding protection
The server SHALL validate the `Origin` header and SHALL bind to the loopback interface by
default.

#### Scenario: Disallowed origin
- **WHEN** a request carries an `Origin` outside the configured allowlist
- **THEN** the server responds `403 Forbidden` and does not process the message

#### Scenario: Allowed origin
- **WHEN** a request carries an allowlisted origin, including any port on that host
- **THEN** the request is processed normally

#### Scenario: No origin header
- **WHEN** a request carries no `Origin` at all, as a non-browser client sends
- **THEN** the request is processed normally

### Requirement: Legacy transport traffic is ignored, not rejected
The server SHALL tolerate headers belonging to superseded revisions of this transport.

#### Scenario: Stale session header
- **WHEN** a request carries `Mcp-Session-Id` or `Last-Event-ID`
- **THEN** the server ignores them, does not mint or echo a session id, and serves the
  request normally

### Requirement: Protocol behaviour is shared with the stdio binding
The HTTP layer SHALL delegate all protocol semantics to the same request processor the
stdio binding uses, and SHALL NOT implement method dispatch of its own.

#### Scenario: Identical results across transports
- **WHEN** the same JSON-RPC request is sent over stdio and over HTTP
- **THEN** the JSON-RPC result body is identical apart from transport framing

### Requirement: Listener backend is selected and disclosed
The server SHALL choose an available listener at startup and SHALL tell the operator which
one is in use and what it implies.

#### Scenario: Forking listener available
- **WHEN** `socat` is installed
- **THEN** the server uses it and reports it

#### Scenario: Only BSD netcat available
- **WHEN** neither `socat` nor `ncat` is installed but `nc` is
- **THEN** the server serves requests one connection at a time and warns that concurrency
  requires `socat`

#### Scenario: No listener at all
- **WHEN** no listener is installed
- **THEN** the server exits with an error naming what to install

### Requirement: Body framing works on the platform's default shell
The transport SHALL read exactly `Content-Length` bytes using constructs available in
bash 3.2, the version macOS provides as `/bin/bash`.

#### Scenario: Exact-length body read
- **WHEN** a request body of a known length arrives, with more bytes following on the
  connection
- **THEN** the server reads exactly the declared number of bytes and parses them as JSON
