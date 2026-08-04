#!/bin/bash
# test_conformance.sh - validate live server output against the OFFICIAL
# published MCP schema (ADR-0003).
#
# The unit suite proves behaviour; this proves wire shape. It drives
# moviemcpserver.sh over a real stdio session and validates each response
# against the matching definition in spec/schema-2026-07-28.json.
#
# Needs Python with `jsonschema`. Without it the test SKIPS rather than fails,
# so jq stays the only hard dependency:
#     python3 -m pip install jsonschema
#     # or point at an interpreter that has it:
#     MCP_CONFORMANCE_PYTHON=/path/to/venv/bin/python ./test_conformance.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/spec/schema-2026-07-28.json"
SERVER="$SCRIPT_DIR/moviemcpserver.sh"
PV="2026-07-28"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

PYTHON="${MCP_CONFORMANCE_PYTHON:-python3}"
if ! "$PYTHON" -c 'import jsonschema' 2>/dev/null; then
    echo -e "${YELLOW}SKIP${NC} conformance tests: '$PYTHON' has no jsonschema module."
    echo "     Install it (python3 -m pip install jsonschema) or set MCP_CONFORMANCE_PYTHON."
    exit 0
fi
[[ -f "$SCHEMA" ]] || { echo -e "${RED}FAIL${NC} schema not found at $SCHEMA"; exit 1; }

meta='"_meta":{"io.modelcontextprotocol/protocolVersion":"'"$PV"'","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"ConformanceHarness","version":"1.0.0"}}'

# Each line: <id> <schema definition to validate the whole response against>
CASES=$(cat <<EOF
1 DiscoverResultResponse
2 ListToolsResultResponse
3 CallToolResultResponse
4 CallToolResultResponse
5 UnsupportedProtocolVersionError
6 JSONRPCErrorResponse
EOF
)

# Drive one real stdio session covering success, tool error, version error and
# unknown-method error.
responses=$( {
  echo '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{'"$meta"'}}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{'"$meta"'}}'
  echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_movies","arguments":{},'"$meta"'}}'
  echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"validate_age","arguments":{"age":9,"movieRating":"A"},'"$meta"'}}'
  echo '{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18","io.modelcontextprotocol/clientCapabilities":{}}}}'
  echo '{"jsonrpc":"2.0","id":6,"method":"resources/list","params":{'"$meta"'}}'
} | "$SERVER" 2>/dev/null )

echo -e "\n${YELLOW}Schema conformance - MCP $PV${NC}\n"

responses_file=$(mktemp)
printf '%s\n' "$responses" >"$responses_file"
trap 'rm -f "$responses_file"' EXIT

MCP_SCHEMA="$SCHEMA" MCP_CASES="$CASES" MCP_RESPONSES="$responses_file" "$PYTHON" - <<'PY'
import json, os, sys
from jsonschema import Draft202012Validator

schema = json.load(open(os.environ["MCP_SCHEMA"]))
# The schema is one document of $defs. Validating an instance against a single
# definition means building a schema that keeps $defs in the same document, so
# every local $ref inside that definition still resolves.
defs = schema["$defs"]

expected = {}
for line in os.environ["MCP_CASES"].strip().splitlines():
    rid, defn = line.split()
    expected[rid] = defn

GREEN, RED, NC = "\033[0;32m", "\033[0;31m", "\033[0m"
failures = 0
seen = set()

for raw in open(os.environ["MCP_RESPONSES"]):
    raw = raw.strip()
    if not raw:
        continue
    msg = json.loads(raw)
    rid = str(msg.get("id"))
    defn = expected.get(rid)
    if defn is None:
        print(f"{RED}FAIL{NC} unexpected response id={rid}")
        failures += 1
        continue
    seen.add(rid)

    validator = Draft202012Validator({"$defs": defs, "$ref": f"#/$defs/{defn}"})
    errors = sorted(validator.iter_errors(msg), key=lambda e: e.path)
    if errors:
        failures += 1
        print(f"{RED}FAIL{NC} id={rid} against {defn}")
        for e in errors[:4]:
            loc = "/".join(str(p) for p in e.absolute_path) or "<root>"
            print(f"       {loc}: {e.message}")
    else:
        print(f"{GREEN}PASS{NC} id={rid} is a valid {defn}")

missing = set(expected) - seen
for rid in sorted(missing):
    print(f"{RED}FAIL{NC} no response for id={rid} (expected {expected[rid]})")
    failures += len(missing)

print()
if failures:
    print(f"{RED}{failures} conformance failure(s){NC}")
    sys.exit(1)
print(f"{GREEN}All responses conform to the published {os.path.basename(os.environ['MCP_SCHEMA'])}{NC}")
PY
