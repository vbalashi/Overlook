#!/usr/bin/env bash
set -euo pipefail

BASE="${OVERLOOK_AGENT_BASE:-http://localhost:9876}"
API_KEY="${OVERLOOK_AGENT_KEY:-}"
OUT_DIR="${OVERLOOK_AGENT_OUT_DIR:-tmp/agent-latency-sweep}"
SLEEP_SECONDS="${OVERLOOK_AGENT_SWEEP_SLEEP:-0.15}"

if [[ -z "$API_KEY" ]]; then
  echo "error: set OVERLOOK_AGENT_KEY to the Agent API key from Overlook settings" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required for CSV extraction" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

AUTH_HEADER="Authorization: Bearer $API_KEY"
JSON_HEADER="Content-Type: application/json"
CSV="$OUT_DIR/sweep.csv"

cat >"$CSV" <<'CSV'
step,hid_x,hid_y,http_status,backend,latency_ms,frame_age_ms,queue_ms,decode_ms,pending,fps,video_kbps
CSV

request_json() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local output="$4"
  local status

  if [[ -n "$body" ]]; then
    status=$(curl -sS -o "$output" -w "%{http_code}" -X "$method" -H "$AUTH_HEADER" -H "$JSON_HEADER" -d "$body" "$BASE$path")
  else
    status=$(curl -sS -o "$output" -w "%{http_code}" -X "$method" -H "$AUTH_HEADER" "$BASE$path")
  fi

  printf '%s' "$status"
}

append_status_row() {
  local step="$1"
  local hid_x="$2"
  local hid_y="$3"
  local status_code="$4"
  local status_file="$5"

  jq -r \
    --arg step "$step" \
    --arg hid_x "$hid_x" \
    --arg hid_y "$hid_y" \
    --arg http_status "$status_code" \
    '[
      $step,
      $hid_x,
      $hid_y,
      $http_status,
      (.backend // ""),
      (.latency_ms // ""),
      (.playout_or_frame_age_ms // ""),
      (.jitter_or_queue_ms // ""),
      (.decode_ms // ""),
      (.lost_or_pending // ""),
      (.fps // ""),
      (.video_kbps // "")
    ] | @csv' "$status_file" >>"$CSV"
}

points=(
  "-26000 -22000"
  "0 -22000"
  "26000 -22000"
  "26000 0"
  "26000 22000"
  "0 22000"
  "-26000 22000"
  "-26000 0"
  "0 0"
  "-12000 -8000"
  "12000 8000"
  "0 0"
)

echo "Overlook Agent latency sweep"
echo "Base: $BASE"
echo "Output: $OUT_DIR"
echo "Sleep between move/status: ${SLEEP_SECONDS}s"
echo

initial_status="$OUT_DIR/status-initial.json"
initial_code=$(request_json GET /video/status "" "$initial_status")
append_status_row "initial" "" "" "$initial_code" "$initial_status"
echo "initial /video/status -> HTTP $initial_code"

step=0
for point in "${points[@]}"; do
  step=$((step + 1))
  read -r hid_x hid_y <<<"$point"
  move_file="$OUT_DIR/move-$step.json"
  status_file="$OUT_DIR/status-$step.json"

  move_code=$(request_json POST /mouse/move "{\"x\":$hid_x,\"y\":$hid_y}" "$move_file")
  sleep "$SLEEP_SECONDS"
  status_code=$(request_json GET /video/status "" "$status_file")
  append_status_row "$step" "$hid_x" "$hid_y" "$status_code" "$status_file"

  latency=$(jq -r '.latency_ms // "null"' "$status_file")
  queue=$(jq -r '.jitter_or_queue_ms // "null"' "$status_file")
  decode=$(jq -r '.decode_ms // "null"' "$status_file")
  pending=$(jq -r '.lost_or_pending // "null"' "$status_file")
  echo "step $step move($hid_x,$hid_y) -> move HTTP $move_code, status HTTP $status_code, latency=${latency}ms queue=${queue}ms decode=${decode}ms pending=$pending"
done

echo
echo "CSV: $CSV"
echo "Max latency rows:"
sort -t, -k6,6nr "$CSV" | head -6
