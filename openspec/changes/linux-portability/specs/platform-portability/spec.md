## ADDED Requirements

### Requirement: Supported platforms
The SDK SHALL run on macOS and on mainstream Linux distributions, including musl/busybox
environments, with `jq` as its only runtime dependency.

#### Scenario: glibc Linux
- **WHEN** the suites run on Debian or Ubuntu with only bash, jq, curl, git and netcat
  installed
- **THEN** every unit and HTTP transport test passes

#### Scenario: musl and busybox Linux
- **WHEN** the suites run on Alpine, where coreutils are busybox applets and libc is musl
- **THEN** every unit and HTTP transport test passes

#### Scenario: macOS system bash
- **WHEN** a server runs under `/bin/bash` on macOS, which is bash 3.2
- **THEN** it serves requests correctly over both transports

#### Scenario: No undeclared dependency
- **WHEN** the SDK runs in a minimal image containing only bash, jq and a netcat
- **THEN** no tool invokes a command that is absent, and in particular nothing depends on
  `bc`

### Requirement: Unbounded data never passes through argv
The SDK SHALL pass tool output and result objects to `jq` on standard input, and SHALL NOT
pass values of unbounded size as command arguments.

#### Scenario: Payload larger than the Linux per-argument limit
- **WHEN** a tool returns 500 KB of output, exceeding the 128 KB `MAX_ARG_STRLEN` ceiling
- **THEN** the server returns a complete, valid response with the payload intact, on Linux
  as well as macOS

#### Scenario: Small values may still be arguments
- **WHEN** the server builds an error response from a short message and an error code
- **THEN** those bounded values MAY be passed as `jq` arguments

### Requirement: Platform-variant commands are resolved empirically
Where a command's invocation differs between platforms, the SDK SHALL determine the working
form by trying it, rather than by inspecting version strings.

#### Scenario: netcat listen syntax
- **WHEN** the HTTP transport starts on a system whose netcat requires `-l -p PORT` rather
  than `-l PORT`
- **THEN** the transport detects this by binding a scratch port and uses the working form

#### Scenario: base64 decoding
- **WHEN** an `Mcp-Name` header arrives base64-encoded on a system whose `base64` accepts
  only `-D` rather than `-d`
- **THEN** the value is still decoded correctly

### Requirement: Shipped scripts target bash 3.2
All scripts in the repository, including development tooling, SHALL avoid syntax introduced
after bash 3.2, because that is the version macOS provides as `/bin/bash`.

#### Scenario: No bash 4+ syntax
- **WHEN** any repository script is parsed by bash 3.2
- **THEN** it parses without error, using no `read -N`, no `declare -A` and no `;&` case
  fallthrough

### Requirement: Cross-platform verification is reproducible
The repository SHALL provide a single command that runs the real test suites on Linux, so
that platform support is a checkable claim.

#### Scenario: Running the matrix
- **WHEN** a developer with Docker runs the Linux test script
- **THEN** the unit suite, HTTP suite, an example server and the large-payload assertion run
  inside each target image, and the command fails if any image fails

#### Scenario: Docker is not required to use the SDK
- **WHEN** a user runs an MCP server without Docker installed
- **THEN** the server works normally, because Docker is needed only to verify other
  platforms
