#!/usr/bin/env bash
set -euo pipefail

BASE="${OVERLOOK_AGENT_BASE:-http://localhost:9876}"
API_KEY="${OVERLOOK_AGENT_KEY:-}"
FIND_TEXT="${OVERLOOK_AGENT_FIND_TEXT:-Login}"
OUT_DIR="${OVERLOOK_AGENT_OUT_DIR:-tmp/agent-smoke}"
EXERCISE_INPUT="${OVERLOOK_AGENT_EXERCISE_INPUT:-0}"

if [[ -z "$API_KEY" ]]; then
  echo "error: set OVERLOOK_AGENT_KEY to the Agent API key from Overlook settings" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

AUTH_HEADER="Authorization: Bearer $API_KEY"
JSON_HEADER="Content-Type: application/json"

request_json() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local name="$4"
  local output="$OUT_DIR/${name}.json"
  local status

  if [[ -n "$body" ]]; then
    status=$(curl -sS -o "$output" -w "%{http_code}" -X "$method" -H "$AUTH_HEADER" -H "$JSON_HEADER" -d "$body" "$BASE$path")
  else
    status=$(curl -sS -o "$output" -w "%{http_code}" -X "$method" -H "$AUTH_HEADER" "$BASE$path")
  fi

  echo "$method $path -> HTTP $status ($output)"
  if [[ "$status" -ge 500 && "$status" -ne 503 ]]; then
    sed -n '1,120p' "$output" >&2
    return 1
  fi
}

echo "Overlook Agent API smoke test"
echo "Base: $BASE"
echo "Output: $OUT_DIR"
echo

request_json GET /status "" status
request_json GET /mouse/position "" mouse-position
request_json POST /convert/pixel-to-hid '{"x":100,"y":100}' pixel-to-hid

shot="$OUT_DIR/screenshot.jpg"
shot_status=$(curl -sS -o "$shot" -w "%{http_code}" -H "$AUTH_HEADER" "$BASE/screenshot?format=jpeg&quality=0.8")
echo "GET /screenshot?format=jpeg&quality=0.8 -> HTTP $shot_status ($shot)"
if [[ "$shot_status" -eq 200 ]]; then
  file "$shot" || true
elif [[ "$shot_status" -eq 503 ]]; then
  sed -n '1,120p' "$shot" >&2 || true
else
  sed -n '1,120p' "$shot" >&2 || true
  exit 1
fi

request_json POST /find-text "{\"text\":\"$FIND_TEXT\"}" find-text

if [[ "$EXERCISE_INPUT" == "1" ]]; then
  echo
  echo "Exercising input endpoints because OVERLOOK_AGENT_EXERCISE_INPUT=1"
  request_json POST /mouse/move '{"x":0,"y":0}' mouse-move
  request_json POST /mouse/scroll '{"deltaX":0,"deltaY":1}' mouse-scroll
  request_json POST /key '{"key":"Escape"}' key-escape
else
  echo
  echo "Skipping input-changing endpoints. Set OVERLOOK_AGENT_EXERCISE_INPUT=1 to test mouse/key actions."
fi

echo
echo "Done. Inspect $OUT_DIR/*.json and $shot"
