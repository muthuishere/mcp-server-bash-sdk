# MCP Server Bash SDK

A [Model Context Protocol](https://modelcontextprotocol.io) server SDK in **pure Bash**,
implementing the current **2026-07-28** revision over both standard transports.

[View on GitHub](https://github.com/muthuishere/mcp-server-bash-sdk){: .btn}

---

## Why Bash, and why now

The 2026-07-28 revision made MCP **stateless**: no `initialize` handshake, no sessions, no
server-initiated requests. One line in, one line out — which is exactly the shape of a
shell read loop. Bash went from an awkward fit to a natural one, and the HTTP binding
collapsed from "sessions, SSE resumability and a long-lived GET stream" to "POST a message,
get JSON back".

A tool is a shell function. That is the whole API:

```bash
tool_get_weather() {
  local location
  location=$(jq -r '.location // ""' <<<"$1")

  if [[ -z "$location" ]]; then
    echo "Missing required parameter: location"   # the model sees this and retries
    return 1
  fi

  curl -s "https://wttr.in/$location?format=j1"
  return 0
}
```

---

## Start here

| | |
| --- | --- |
| **[Quick start](https://github.com/muthuishere/mcp-server-bash-sdk#-quick-start)** | Clone it and send a request in two commands |
| **[Examples](https://github.com/muthuishere/mcp-server-bash-sdk/tree/main/examples)** | Four runnable servers and a build-your-own walkthrough |
| **[Architecture decisions](adr/)** | Why the SDK is shaped this way, and what was rejected |

---

## What it does

- MCP **2026-07-28** — stateless, per-request version negotiation, `server/discover`
- **Both standard transports** — stdio and Streamable HTTP, from the same server file
- Tools discovered by shell function name; configuration in JSON files
- Output validated against the **official published JSON Schema**
- One runtime dependency: `jq`

## What it does not do

Stated plainly, because a limitation you discover in production is worse than one you read
up front:

- **HTTP is a local endpoint** — loopback bind, no TLS, no auth. Front it with a reverse
  proxy to expose it.
- **No SSE response mode**, so no progress streaming and no `subscriptions/listen`.
- **No concurrency on stdio** — one client, one process, roughly 30 requests/second.
- **Clients older than `2026-07-28` are rejected** with `-32022`. Deliberate; see
  [ADR-0002](adr/0002-target-2026-07-28-only.html).

---

## How it is built

Two habits run through this repository, and the documents below are the output of both.

**Decisions are written down with what was rejected.** Seven
[architecture decision records](adr/) cover the transports, the protocol revision, the
conformance strategy, the `jq` budget, and tool-error semantics. ADR-0001 chose stdio-only
and is now superseded in scope by ADR-0006 — the reversal is recorded rather than edited
away, because the protocol changed underneath it.

**Claims are measured, not asserted.** Three runnable spikes back the numbers:

- **[Is stdio good enough?](spikes/spike-01-findings.html)** — 200 requests, zero lost,
  4 MB single lines intact. `jq` forks are the entire cost, not bash.
- **[Can Bash serve Streamable HTTP?](spikes/spike-02-http-listener.html)** — yes, and
  `read -N` does not exist in the bash 3.2 that macOS ships as `/bin/bash`.
- **[Does it actually run on Linux?](spikes/spike-03-linux-portability.html)** — it does
  now. It did not before: Linux caps a single `argv` entry at 128 KB, which macOS does not,
  so any tool returning a large payload failed only in production.

Verified on macOS (bash 3.2 and 5.3), Debian, Alpine (musl + busybox) and Ubuntu —
`./scripts/test-linux.sh all` reproduces the Linux rows.

---

## Community

Questions, ideas, or built something with this? Join
**[AgentNexus](https://discord.gg/V9C2kvHC8D)** — this project lives in `#mcp-bash-sdk`.
