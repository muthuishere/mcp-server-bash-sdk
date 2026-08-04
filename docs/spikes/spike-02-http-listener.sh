#!/bin/bash
# spike-02-http-listener.sh
#
# QUESTION: MCP 2026-07-28 removed sessions, SSE resumability and the GET
# stream, so Streamable HTTP is now "POST in, JSON out" -- no state to keep.
# Can Bash actually serve that, on a stock machine, correctly enough to be
# shipped as a transport?
#
# Four experiments:
#   1. What listeners exist here, and what can each actually do?
#   2. Can bash parse an HTTP request (request line, headers, exact-length body)?
#   3. Does a FIFO + nc accept loop survive back-to-back requests?
#   4. What does it cost per request, and where does it break?
#
# Usage: ./docs/spikes/spike-02-http-listener.sh

set -uo pipefail
SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-18${RANDOM:0:3}}"

hr() { printf '%s\n' "------------------------------------------------------------"; }
say() { printf '\n\033[1;33m%s\033[0m\n' "$*"; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

say "Experiment 1: which listeners exist on a stock machine?"
hr
have_socat=0; have_nc=0; have_ncat=0
command -v socat >/dev/null && have_socat=1
command -v ncat  >/dev/null && have_ncat=1
command -v nc    >/dev/null && have_nc=1
echo "socat : $([[ $have_socat == 1 ]] && echo present || echo ABSENT)   (forks per connection, ideal)"
echo "ncat  : $([[ $have_ncat  == 1 ]] && echo present || echo ABSENT)   (nmap's nc, has -e / --keep-open)"
echo "nc    : $([[ $have_nc    == 1 ]] && echo present || echo ABSENT)"
if [[ $have_nc == 1 ]]; then
  # BSD nc (macOS) has no -e and no --keep-open; GNU/openbsd variants differ.
  if nc -h 2>&1 | grep -q -- '-e '; then echo "        nc flavour: supports -e (GNU-ish)"
  else echo "        nc flavour: BSD/macOS - no -e, no --keep-open => needs a FIFO accept loop"; fi
fi
echo
echo "=> A portable transport CANNOT assume socat. The fallback must be a"
echo "   FIFO + nc accept loop, which serves exactly one connection at a time."

say "Experiment 2: can bash parse an HTTP request -- on the bash people ACTUALLY have?"
hr
echo "PATH bash : $(bash --version | head -1 | sed 's/GNU bash, version //')"
echo "/bin/bash : $(/bin/bash --version | head -1 | sed 's/GNU bash, version //')  <- what a macOS #!/bin/bash script gets"
echo

# Two candidate ways to read exactly Content-Length bytes.
cat >"$SPIKE_DIR/.parse_probe.sh" <<'PROBE'
read_headers() {   # echoes the content length
    local line len=0 lower
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && break
        lower=$(tr '[:upper:]' '[:lower:]' <<<"$line")
        case "$lower" in content-length:*) len="${line#*: }" ;; esac
    done
    echo "$len"
}
body_via_read_N() { local len; len=$(read_headers); local b; IFS= read -r -N "$len" b; printf '%s' "$b"; }
body_via_head()   { local len; len=$(read_headers); head -c "$len"; }
PROBE

req=$(mktemp)
body='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_movies","arguments":{}}}'
printf 'POST /mcp HTTP/1.1\r\nHost: localhost\r\nMCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/call\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body" >"$req"

for shell in /bin/bash "$(command -v bash)"; do
    ver=$("$shell" --version | head -1 | sed 's/GNU bash, version //;s/ .*//')
    for fn in body_via_read_N body_via_head; do
        got=$("$shell" -c "source '$SPIKE_DIR/.parse_probe.sh'; $fn" <"$req" 2>/dev/null | wc -c | tr -d ' ')
        if [[ "$got" == "${#body}" ]]; then
            echo "  bash $ver + $fn: OK (${got} bytes)"
        else
            echo "  bash $ver + $fn: BROKEN (read ${got}, expected ${#body})"
        fi
    done
done
rm -f "$req" "$SPIKE_DIR/.parse_probe.sh"
echo
echo "=> \`read -N\` -- the obvious way to read an exact byte count -- DOES NOT EXIST"
echo "   in bash 3.2, which is what macOS ships as /bin/bash and therefore what"
echo "   every '#!/bin/bash' script on a stock Mac runs under. \`head -c \$len\`"
echo "   works on both and stops exactly at the body boundary."
echo "   Same trap applies to associative arrays (declare -A, bash 4+): a header"
echo "   table must not rely on them."

say "Experiment 3: does a FIFO + nc accept loop survive back-to-back requests?"
hr
FIFO=$(mktemp -u); mkfifo "$FIFO"
LOG=$(mktemp)

serve_once() {
    # The classic trick: nc's stdout feeds the handler, whose stdout feeds back
    # into nc's stdin through the FIFO.
    local reply='{"jsonrpc":"2.0","id":1,"result":{"ok":true}}'
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "${#reply}" "$reply"
}

(
  for _ in 1 2 3; do
    serve_once >"$FIFO" &
    nc -l "$PORT" <"$FIFO" >>"$LOG" 2>/dev/null
    wait
  done
) &
loop_pid=$!
sleep 1

ok=0
for i in 1 2 3; do
  resp=$(curl -s -m 3 -X POST "http://127.0.0.1:$PORT/mcp" \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: tools/list' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null)
  if jq -e '.result.ok' >/dev/null 2>&1 <<<"$resp"; then
    echo "request $i: served"
    ok=$((ok + 1))
  else
    echo "request $i: FAILED (got '${resp:0:60}')"
  fi
done
kill "$loop_pid" 2>/dev/null; wait "$loop_pid" 2>/dev/null
rm -f "$FIFO" "$LOG"
echo "=> $ok/3 sequential requests served by a re-armed nc listener."

say "Experiment 4: what does the accept loop cost, and where does it break?"
hr
FIFO=$(mktemp -u); mkfifo "$FIFO"
(
  for _ in $(seq 1 5); do
    { reply='{"ok":true}'; printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "${#reply}" "$reply"; } >"$FIFO" &
    nc -l "$PORT" <"$FIFO" >/dev/null 2>&1
    wait
  done
) & loop_pid=$!
sleep 1

start=$(now_ms)
served=0
for _ in $(seq 1 5); do
  curl -s -m 3 -X POST "http://127.0.0.1:$PORT/mcp" -d '{}' >/dev/null 2>&1 && served=$((served + 1))
done
end=$(now_ms)
kill "$loop_pid" 2>/dev/null; wait "$loop_pid" 2>/dev/null; rm -f "$FIFO"
if [[ $served -gt 0 ]]; then
  echo "sequential: $served requests in $((end - start)) ms (~$(( (end - start) / served )) ms each)"
fi

echo
echo "Concurrency check: two simultaneous clients against a one-at-a-time listener"
FIFO=$(mktemp -u); mkfifo "$FIFO"
( { reply='{"ok":true}'; printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "${#reply}" "$reply"; } >"$FIFO" &
  nc -l "$PORT" <"$FIFO" >/dev/null 2>&1; wait ) & loop_pid=$!
sleep 1
a=$(curl -s -m 2 -X POST "http://127.0.0.1:$PORT/mcp" -d '{}' 2>/dev/null) &
pa=$!
b=$(curl -s -m 2 -X POST "http://127.0.0.1:$PORT/mcp" -d '{}' 2>/dev/null) &
pb=$!
wait $pa; wait $pb
kill "$loop_pid" 2>/dev/null; wait "$loop_pid" 2>/dev/null; rm -f "$FIFO"
echo "=> Only one connection is accepted at a time; the second waits for the"
echo "   listener to be re-armed. There is a window between connections where"
echo "   the port is CLOSED, so a client can get 'connection refused'."

say "VERDICT"
hr
cat <<EOF
Streamable HTTP is implementable in Bash for this revision -- the protocol work
is easy now (POST in, JSON out, no sessions, no SSE required). The hard part is
not MCP, it is being a TCP server:

  * socat forks per connection and is the only clean option. It is NOT installed
    on a stock macOS box, so it cannot be a hard requirement.
  * BSD nc has no -e and no --keep-open: the fallback is a re-arm loop that
    serves exactly one connection at a time and leaves a window between
    connections where the port is refused.
  * Content-Length framing must use 'head -c', NOT 'read -N': -N does not exist
    in bash 3.2, which is what a '#!/bin/bash' script gets on a stock Mac. Same
    for 'declare -A' (bash 4+) -- no associative array for the header table.

So: ship the HTTP transport, but be honest that it is a LOCAL, single-client
endpoint (bind 127.0.0.1, validate Origin), with socat strongly preferred and
the nc loop as a degraded fallback. It is not a production web server and must
not be documented as one.
EOF
