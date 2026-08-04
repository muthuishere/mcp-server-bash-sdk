## ADDED Requirements

### Requirement: JSON-RPC 2.0 envelope validation
The server SHALL accept only well-formed JSON-RPC 2.0 messages and SHALL reject anything
else with error code `-32600` (Invalid Request).

#### Scenario: Wrong protocol envelope
- **WHEN** a message arrives whose `jsonrpc` field is not exactly `"2.0"`
- **THEN** the server responds with error code `-32600` and preserves the request `id`

#### Scenario: Unparseable input
- **WHEN** a line arrives that is not valid JSON
- **THEN** the server responds with error code `-32700` (Parse error) and `id: null`

#### Scenario: Blank line
- **WHEN** an empty or whitespace-only line arrives
- **THEN** the server emits nothing at all

### Requirement: Per-request protocol version negotiation
The server SHALL read the protocol version from
`params._meta["io.modelcontextprotocol/protocolVersion"]` on every request and SHALL NOT
retain version state between requests.

#### Scenario: Supported version
- **WHEN** a request declares protocol version `2026-07-28`
- **THEN** the server processes it normally

#### Scenario: Unsupported version
- **WHEN** a request declares any other protocol version, for example `2025-06-18`
- **THEN** the server responds with error code `-32022`, and the error `data` object
  contains `requested` set to the declared version and `supported` listing `2026-07-28`

#### Scenario: Version absent
- **WHEN** a request omits `params._meta["io.modelcontextprotocol/protocolVersion"]`
- **THEN** the server responds with error code `-32022` reporting the empty request

#### Scenario: No cross-request memory
- **WHEN** a request with a supported version is followed by one with an unsupported version
- **THEN** the second request is rejected regardless of the first having succeeded

### Requirement: server/discover
The server SHALL implement `server/discover`, returning its supported protocol versions,
capabilities, instructions, and cache hints.

#### Scenario: Discovery result shape
- **WHEN** a client sends `server/discover`
- **THEN** the result contains `supportedVersions`, `capabilities`, `resultType`,
  `ttlMs`, and `cacheScope`, and validates against the published `DiscoverResult` schema

#### Scenario: Discovery bypasses version negotiation
- **WHEN** a client sends `server/discover` declaring an unsupported protocol version
- **THEN** the server still returns a `DiscoverResult` so the client can learn which
  versions are available

### Requirement: Result envelope
Every successful result SHALL carry `resultType` and SHALL identify the server.

#### Scenario: resultType present
- **WHEN** any request succeeds
- **THEN** the result object contains `resultType: "complete"`

#### Scenario: serverInfo present
- **WHEN** any request succeeds
- **THEN** the result `_meta` contains `io.modelcontextprotocol/serverInfo` with `name`
  and `version`

### Requirement: Cacheable list results
Results of list-style methods SHALL carry cache hints.

#### Scenario: tools/list cache hints
- **WHEN** a client calls `tools/list`
- **THEN** the result contains an integer `ttlMs` of at least 0 and a `cacheScope` of
  either `"public"` or `"private"`

#### Scenario: Deterministic ordering
- **WHEN** `tools/list` is called twice against an unchanged server
- **THEN** the tools appear in identical order both times

### Requirement: Error code allocation
The server SHALL use only error codes the specification permits, and SHALL NOT invent
codes inside the specification-reserved range.

#### Scenario: Unknown method
- **WHEN** a request names a method the server does not implement
- **THEN** the server responds with error code `-32601`

#### Scenario: Reserved range respected
- **WHEN** the server emits any error
- **THEN** the code is either a standard JSON-RPC code or one of the spec-defined codes
  `-32020`, `-32021`, `-32022`

### Requirement: Notifications produce no response
The server SHALL treat JSON-RPC notifications as fire-and-forget.

#### Scenario: Cancellation notification
- **WHEN** a `notifications/cancelled` notification arrives
- **THEN** the server emits nothing on stdout

#### Scenario: Unknown notification
- **WHEN** a message with no `id` arrives naming an unrecognised method
- **THEN** the server emits nothing on stdout

## REMOVED Requirements

### Requirement: initialize handshake
**Reason**: MCP `2026-07-28` removes the `initialize` / `notifications/initialized`
handshake; protocol version and client capabilities now travel on every request in
`params._meta`.
**Migration**: Clients call `server/discover` for identity, capabilities and supported
versions, then send the chosen version in `params._meta` on each subsequent request.
