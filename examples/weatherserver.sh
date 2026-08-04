#!/bin/bash
# weatherserver.sh - a worked example: wrap a third-party HTTP API.
#
# This is the shape most MCP servers actually take -- an API wrapper. It shows
# the parts that matter and are easy to get wrong: keeping secrets out of the
# code, failing usefully when the network does, and turning someone else's
# response into something a model can act on.
#
#     ./examples/weatherserver.sh                  # stdio
#     ./examples/weatherserver.sh --http           # Streamable HTTP on :3000
#
# Uses wttr.in, which needs no API key. WEATHER_API_KEY is read from the
# environment to show where a key WOULD go -- never hardcode one.

SDK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MCP_CONFIG_FILE="$SDK_DIR/examples/assets/weatherserver_config.json"
MCP_TOOLS_LIST_FILE="$SDK_DIR/examples/assets/weatherserver_tools.json"
MCP_LOG_FILE="$SDK_DIR/logs/weatherserver.log"

source "$SDK_DIR/mcpserver_core.sh"
source "$SDK_DIR/mcpserver_http.sh"

WEATHER_BASE_URL="${WEATHER_BASE_URL:-https://wttr.in}"
# Secrets come from the environment, never from the source. This one is unused
# by wttr.in; it is here to show the pattern.
WEATHER_API_KEY="${WEATHER_API_KEY:-}"
WEATHER_TIMEOUT="${WEATHER_TIMEOUT:-10}"

# --- helpers --------------------------------------------------------------

# A location goes into a URL, so constrain it. Letters, digits, spaces, commas,
# dots and hyphens cover real place names and nothing else.
valid_location() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9\ ,.\'-]{0,80}$ ]]
}

# URL-encode with jq -- @uri is exactly this, and avoids hand-rolling it.
url_encode() {
    jq -rn --arg s "$1" '$s | @uri'
}

# --- tools ----------------------------------------------------------------

# Tool: current conditions for a location.
tool_get_weather() {
    local args="$1"
    local location encoded response http_status

    location=$(jq -r '.location // ""' <<<"$args")

    if [[ -z "$location" ]]; then
        echo "Missing required parameter: location"
        return 1
    fi
    if ! valid_location "$location"; then
        echo "Invalid location '$location': use a place name like 'Chennai' or 'Paris, France'"
        return 1
    fi

    encoded=$(url_encode "$location")

    # Capture body and status separately so a 404 is not mistaken for data.
    local tmp; tmp=$(mktemp)
    http_status=$(curl -sS -m "$WEATHER_TIMEOUT" -o "$tmp" -w '%{http_code}' \
        ${WEATHER_API_KEY:+-H "Authorization: Bearer $WEATHER_API_KEY"} \
        "$WEATHER_BASE_URL/$encoded?format=j1" 2>/dev/null)
    response=$(cat "$tmp"); rm -f "$tmp"

    # Network failures are the common case for an API wrapper. Say what went
    # wrong -- the model can then retry, or tell the user, instead of guessing.
    if [[ -z "$http_status" || "$http_status" == "000" ]]; then
        echo "Could not reach the weather service at $WEATHER_BASE_URL (network error or timeout after ${WEATHER_TIMEOUT}s)"
        return 1
    fi
    if [[ "$http_status" -ge 400 ]]; then
        echo "Weather service returned HTTP $http_status for '$location'. The location may not exist."
        return 1
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$response"; then
        echo "Weather service returned a non-JSON response (HTTP $http_status)"
        return 1
    fi

    # Reshape into the handful of fields a model actually needs. Passing the
    # upstream payload through untouched would spend hundreds of tokens on
    # fields nobody reads.
    jq -c --arg location "$location" '
        {
          location: $location,
          observedAt: .current_condition[0].observation_time,
          temperatureC: (.current_condition[0].temp_C | tonumber),
          feelsLikeC: (.current_condition[0].FeelsLikeC | tonumber),
          description: .current_condition[0].weatherDesc[0].value,
          humidityPercent: (.current_condition[0].humidity | tonumber),
          windKph: (.current_condition[0].windspeedKmph | tonumber)
        }' <<<"$response"
    return 0
}

# Tool: a short forecast, so the example has more than one shape of output.
tool_get_forecast() {
    local args="$1"
    local location days encoded response http_status

    location=$(jq -r '.location // ""' <<<"$args")
    days=$(jq -r '.days // 3' <<<"$args")

    if [[ -z "$location" ]]; then
        echo "Missing required parameter: location"
        return 1
    fi
    if ! valid_location "$location"; then
        echo "Invalid location '$location': use a place name like 'Chennai' or 'Paris, France'"
        return 1
    fi
    if ! [[ "$days" =~ ^[0-9]+$ ]] || [[ "$days" -lt 1 || "$days" -gt 3 ]]; then
        echo "Invalid days: must be between 1 and 3 (got '$days')"
        return 1
    fi

    encoded=$(url_encode "$location")
    local tmp; tmp=$(mktemp)
    http_status=$(curl -sS -m "$WEATHER_TIMEOUT" -o "$tmp" -w '%{http_code}' \
        "$WEATHER_BASE_URL/$encoded?format=j1" 2>/dev/null)
    response=$(cat "$tmp"); rm -f "$tmp"

    if [[ -z "$http_status" || "$http_status" == "000" ]]; then
        echo "Could not reach the weather service at $WEATHER_BASE_URL (network error or timeout after ${WEATHER_TIMEOUT}s)"
        return 1
    fi
    if [[ "$http_status" -ge 400 ]]; then
        echo "Weather service returned HTTP $http_status for '$location'. The location may not exist."
        return 1
    fi

    jq -c --arg location "$location" --argjson days "$days" '
        {
          location: $location,
          forecast: (.weather[0:$days] | map({
            date: .date,
            minC: (.mintempC | tonumber),
            maxC: (.maxtempC | tonumber),
            description: .hourly[4].weatherDesc[0].value
          }))
        }' <<<"$response"
    return 0
}

# --- entry point ----------------------------------------------------------

case "${1:-}" in
--http)
    shift
    run_mcp_http_server "$@"
    ;;
handle-connection)
    run_mcp_http_server handle-connection
    ;;
*)
    run_mcp_server "$@"
    ;;
esac
