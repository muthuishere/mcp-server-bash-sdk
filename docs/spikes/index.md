# Spikes

Runnable experiments, not prose. Every performance or portability claim in this repository
traces back to one of these, and each script can be re-run to refresh its numbers.

| Spike | Question | Answer |
| --- | --- | --- |
| [01](spike-01-findings.md) — [script](https://github.com/muthuishere/mcp-server-bash-sdk/blob/main/docs/spikes/spike-01-stdio-viability.sh) | Is stdio good enough to be the only transport? | Yes — ~34 ms/request, no message loss, 4 MB lines intact. `jq` forks are the cost, not bash. |
| [02](spike-02-http-listener.md) — [script](https://github.com/muthuishere/mcp-server-bash-sdk/blob/main/docs/spikes/spike-02-http-listener.sh) | Can Bash serve Streamable HTTP? | Yes. The hard part is being a TCP server — and `read -N` does not exist in macOS's bash 3.2. |
| [03](spike-03-linux-portability.md) — [script](https://github.com/muthuishere/mcp-server-bash-sdk/blob/main/scripts/test-linux.sh) | Does it actually run on Linux? | It does now. It did not before: Linux caps a single `argv` entry at 128 KB; macOS does not. |

Each spike feeds a decision in [`docs/adr/`](../adr/).
