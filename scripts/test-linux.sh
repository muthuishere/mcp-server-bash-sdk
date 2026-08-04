#!/bin/bash
# test-linux.sh - run the whole test suite on Linux, in Docker, from macOS.
#
# "It works on my machine" is not a portability claim. This runs the real suites
# inside real Linux images so the claim is checkable by anyone with Docker.
#
#   ./scripts/test-linux.sh              # debian (glibc, GNU coreutils, openbsd nc)
#   ./scripts/test-linux.sh alpine       # busybox + musl -- the strictest target
#   ./scripts/test-linux.sh all          # every image, sequentially
#
# Each image is deliberately minimal: only bash, jq and a netcat are installed,
# so a hidden dependency shows up as a failure instead of silently working.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-debian}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

command -v docker >/dev/null || { echo "docker is required"; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker daemon is not running"; exit 1; }

# The suite body, run identically inside every image.
read -r -d '' SUITE <<'INNER'
set -u
cd /work
chmod +x ./*.sh examples/*.sh docs/spikes/*.sh 2>/dev/null
git config --global --add safe.directory /work 2>/dev/null

echo "  bash    : $(bash --version | head -1 | sed 's/GNU bash, version //')"
echo "  jq      : $(jq --version 2>/dev/null || echo ABSENT)"
echo "  netcat  : $( (nc -h 2>&1 || true) | head -1 )"
echo "  coreutils: $(head --version 2>/dev/null | head -1 || echo 'busybox/BSD')"
echo

fails=0

echo "--- unit tests ---"
./test_mcpserver_core.sh >/tmp/unit.log 2>&1
if [ $? -eq 0 ]; then
    echo "  $(grep -o '[0-9]*/[0-9]* passed' /tmp/unit.log | tail -1) OK"
else
    echo "  FAILED"; grep -B1 -A4 'FAIL' /tmp/unit.log | head -40; fails=$((fails+1))
fi

echo "--- HTTP transport tests ---"
./test_http_transport.sh >/tmp/http.log 2>&1
if [ $? -eq 0 ]; then
    echo "  $(grep -o '[0-9]*/[0-9]* passed' /tmp/http.log | tail -1) OK"
else
    echo "  FAILED"; grep -B1 -A4 'FAIL' /tmp/http.log | head -40; fails=$((fails+1))
fi

echo "--- example server over stdio ---"
META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
out=$(echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"git_status\",\"arguments\":{},$META}}" \
      | ./examples/gitserver.sh | jq -r '.result.content[0].text' 2>/dev/null)
if echo "$out" | jq -e '.branch' >/dev/null 2>&1; then
    echo "  git_status OK"
else
    echo "  FAILED: $out"; fails=$((fails+1))
fi

echo "--- large payload (>128KB, the Linux MAX_ARG_STRLEN limit) ---"
out=$(echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"big\",\"arguments\":{},$META}}" \
      | bash -c '
        MCP_CONFIG_FILE=/work/assets/movieserver_config.json
        MCP_TOOLS_LIST_FILE=/work/assets/movieserver_tools.json
        MCP_LOG_FILE=/tmp/big.log
        source /work/mcpserver_core.sh
        tool_big() { jq -rn "\"x\" * 500000"; }
        run_mcp_server' | jq -r '.result.content[0].text | length' 2>/dev/null)
if [ "$out" = "500000" ]; then
    echo "  500 KB payload intact OK"
else
    echo "  FAILED: got '$out', expected 500000"; fails=$((fails+1))
fi

exit $fails
INNER

run_image() { # run_image <label> <image> <install-command>
    local label="$1" image="$2" install="$3"
    echo -e "\n${YELLOW}=== $label ($image) ===${NC}"
    # The suite goes in on stdin and runs under `bash -s`, so no quoting
    # gymnastics and no temp files inside the image.
    if printf '%s\n' "$SUITE" | docker run -i --rm -v "$REPO_DIR:/sdk:ro" "$image" sh -c "
        $install >/dev/null 2>&1
        mkdir -p /work && cp -r /sdk/. /work/ 2>/dev/null
        exec bash -s
    "; then
        echo -e "${GREEN}PASS${NC} $label"
        return 0
    else
        echo -e "${RED}FAIL${NC} $label"
        return 1
    fi
}

# No `;&` case fallthrough here: that is bash 4+, and this script has to run on
# the bash 3.2 that macOS provides -- the same trap the SDK itself avoids.
case "$TARGET" in
debian | alpine | ubuntu | all) ;;
*)
    echo "Unknown target '$TARGET'. Use: debian | alpine | ubuntu | all"
    exit 1
    ;;
esac

failed=0

if [[ "$TARGET" == "debian" || "$TARGET" == "all" ]]; then
    run_image "Debian (glibc, GNU coreutils, openbsd-nc)" debian:stable-slim \
        "apt-get update -qq && apt-get install -y -qq jq curl git netcat-openbsd" || failed=$((failed + 1))
fi

if [[ "$TARGET" == "alpine" || "$TARGET" == "all" ]]; then
    run_image "Alpine (musl, busybox coreutils)" alpine:latest \
        "apk add --no-cache bash jq curl git netcat-openbsd" || failed=$((failed + 1))
fi

if [[ "$TARGET" == "ubuntu" || "$TARGET" == "all" ]]; then
    run_image "Ubuntu LTS" ubuntu:24.04 \
        "apt-get update -qq && apt-get install -y -qq jq curl git netcat-openbsd" || failed=$((failed + 1))
fi

echo
if [[ $failed -gt 0 ]]; then
    echo -e "${RED}$failed image(s) failed${NC}"
    exit 1
fi
echo -e "${GREEN}All images passed${NC}"
