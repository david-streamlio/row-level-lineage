#!/usr/bin/env bash
# demo/record-demo.sh -- automated screen recording of the row-level lineage
# demo, one clip per stage. Same approach as fleet-trilogy's
# deploy/record-talk3-demo.sh: Terminal.app windows placed on the external
# display, ONE ffmpeg avfoundation capture of that display, and an export that
# crops each window's content area onto a black canvas (title bars, the desktop
# and other apps never reach the video). No audio. Plus one thing talk 3 never
# needed: a browser window (Chrome in app mode, no tabs or address bar) for the
# Lakekeeper catalog UI and the Marquez lineage graph.
#
# Recorded windows, all on the external display:
#   writer (runs demo/run-stage.sh N) | browser (Lakekeeper / Marquez)
#   Kafka topic (raw events)          | SQL (row lineage, every 2 s) | lineage feed
# Each stage sets the SQL window's query and the browser's page (see stage_*
# below); stage 4 runs with customer 9001 so its join lands on stage 2's row.
#
# Usage:
#   demo/record-demo.sh [STAGE ...] [options]     # default: all stages, 1-5
#
# Options:
#   --no-reset          don't run `demo/run-stage.sh reset` first (default: reset
#                       when stage 1 is recorded -- the stages expect a clean start)
#   --font-size N       recorded terminals' font size, points (default: 18; the writer gets N-2)
#   --lead-in SEC       recorded before each stage starts, then trimmed (default: 3)
#   --tail SEC          recorded after each stage ends, browser on its final page (default: 8)
#   --output-dir DIR    where the clips go (default: demo/recordings)
#   --teardown          close every window this script opened afterwards
#
# Output: <output-dir>/stage<N>-<timestamp>.mp4 per stage (H.264), plus the raw
# captures (.raw-*) and logs. Stills for slides: ffmpeg -ss <sec> -i clip.mp4 -frames:v 1 still.png
#
# Requires: macOS with an external display, Google Chrome, ffmpeg/ffprobe, Node 22+
# (scrolls the browser via the DevTools protocol), the
# demo's own prerequisites (Docker, jq, python3). The terminal running this needs
# Screen Recording + Automation permission. Record online: offline, Marquez's
# fonts fall back to serif.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../scripts/lib.sh"
set +e   # lib.sh turns on -e; like record-talk3-demo.sh, this script checks what matters itself
WIN_DIR="${SCRIPT_DIR}/record-windows"

STAGES=()
RESET="auto"
FONT_SIZE="18"
WRITER_FONT_SIZE="16"
PROFILE="Clear Dark"
LEAD_IN="3"
TAIL="8"
OUTPUT_DIR="${ROOT_DIR}/demo/recordings"
TEARDOWN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-reset) RESET=""; shift ;;
    --font-size) FONT_SIZE="${2:?}"; WRITER_FONT_SIZE=$(( ${2:?} - 2 )); shift 2 ;;
    --lead-in) LEAD_IN="${2:?}"; shift 2 ;;
    --tail) TAIL="${2:?}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:?}"; shift 2 ;;
    --teardown) TEARDOWN="1"; shift ;;
    [1-5]) STAGES+=("$1"); shift ;;
    *) echo "[record] unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ "${#STAGES[@]}" -gt 0 ]] || STAGES=(1 2 3 4 5)
if [[ "${RESET}" == auto ]]; then RESET=""; [[ " ${STAGES[*]} " == *" 1 "* ]] && RESET="1"; fi

log() { echo "[record] $*"; }
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

for tool in osascript ffmpeg ffprobe python3 docker jq curl node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "[record] required tool not found: ${tool}" >&2; exit 1; }
done
[[ -d "/Applications/Google Chrome.app" ]] || { echo "[record] Google Chrome not found" >&2; exit 1; }

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "${OUTPUT_DIR}"
STATE_DIR="/tmp/rll-record-${TIMESTAMP}"   # done markers + Chrome profile; outside out/ (reset wipes it)
mkdir -p "${STATE_DIR}"
CHROME_DIR="${STATE_DIR}/chrome"
CDP_PORT=9333   # DevTools port of the recorder's own Chrome instance (scrolling)
QUERY_FILE="${ROOT_DIR}/out/.record/sql-query.sql"   # out/ is mounted into duckdb-demo at /work/out

# --- display geometry (as in record-talk3-demo.sh): top-left-origin points
read -r MAIN_W MAIN_H EXT_X EXT_Y EXT_W EXT_H VIS_X VIS_Y VIS_W VIS_H <<EOF
$(osascript -l JavaScript <<'JXA'
ObjC.import("AppKit");
var screens = $.NSScreen.screens, mainJs = $.NSScreen.mainScreen.js, main = null, ext = null;
for (var i = 0; i < screens.count; i++) {
  var s = screens.objectAtIndex(i);
  if (s.js === mainJs) { main = s; } else if (!ext) { ext = s; }
}
var r = "";
if (main && ext) {
  var mf = main.frame, ef = ext.frame, ev = ext.visibleFrame;
  r = [mf.size.width, mf.size.height, ef.origin.x, mf.size.height - (ef.origin.y + ef.size.height), ef.size.width, ef.size.height,
       ev.origin.x, mf.size.height - (ev.origin.y + ev.size.height), ev.size.width, ev.size.height].join(" ");
}
r
JXA
)
EOF
[[ -n "${EXT_W:-}" ]] || { echo "[record] no external display found -- this recorder records on the external display" >&2; exit 1; }
log "external display: origin (${EXT_X},${EXT_Y}) size ${EXT_W}x${EXT_H}; usable ${VIS_W}x${VIS_H} at (${VIS_X},${VIS_Y})"
if python3 -c "import sys; sys.exit(0 if abs(${MAIN_W}/${MAIN_H} - ${EXT_W}/${EXT_H}) < 0.01 else 1)"; then
  echo "[record] both displays have the same aspect ratio -- can't tell them apart safely" >&2; exit 1
fi

# --- slots on the external display (points), inside its usable area: above
# its Dock (macOS moves a window that would overlap it -- even to another
# display) and TOP_INSET below its top edge, which window title bars can't
# enter (observed: Chrome and Terminal both stop 30 pt below it). Capture
# coordinates still use the full frame (EXT_*). Each stage shows only the 2-3
# windows its slides need, in big slots with big fonts (legible from the back
# of the room); the others are parked on the main display, which isn't recorded.
#   L | R   (two windows)    L | RT / RB  or  LT / LB | R   (three windows)
MARGIN=15; GAP=15; TOP_INSET=30
AREA_Y=$(( VIS_Y + TOP_INSET )); AREA_H=$(( VIS_H - TOP_INSET ))
HALF_W=$(( (VIS_W - 2 * MARGIN - GAP) / 2 ))
L_X=$(( VIS_X + MARGIN )); R_X=$(( L_X + HALF_W + GAP ))
TOP_Y=$(( AREA_Y + MARGIN )); BOTTOM_Y=$(( AREA_Y + AREA_H - MARGIN ))
HALF_H=$(( (BOTTOM_Y - TOP_Y - GAP) / 2 ))
slot_bounds() {  # slot_bounds <L|R|RT|RB> -> "x1 y1 x2 y2"
  case "$1" in
    L)  echo "$L_X $TOP_Y $(( L_X + HALF_W )) $BOTTOM_Y" ;;
    R)  echo "$R_X $TOP_Y $(( R_X + HALF_W )) $BOTTOM_Y" ;;
    RT) echo "$R_X $TOP_Y $(( R_X + HALF_W )) $(( TOP_Y + HALF_H ))" ;;
    RB) echo "$R_X $(( TOP_Y + HALF_H + GAP )) $(( R_X + HALF_W )) $BOTTOM_Y" ;;
    LT) echo "$L_X $TOP_Y $(( L_X + HALF_W )) $(( TOP_Y + HALF_H ))" ;;
    LB) echo "$L_X $(( TOP_Y + HALF_H + GAP )) $(( L_X + HALF_W )) $BOTTOM_Y" ;;
    F)  echo "$L_X $TOP_Y $(( R_X + HALF_W )) $BOTTOM_Y" ;;   # full width (MinIO's file list)
  esac
}
PARK_BOUNDS=(40 80 760 560)   # main display: where a stage's unused windows wait

# --- windows
WINDOW_IDS=()
RECORD_PIDS=()
cleanup() {
  local code=$?
  trap - EXIT
  for pid in "${RECORD_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kill -INT "$pid" 2>/dev/null
  done
  if [[ -n "$TEARDOWN" ]]; then
    log "tearing down..."
    pkill -f "user-data-dir=${CHROME_DIR}" 2>/dev/null || true
    pkill -f "docker exec -it lineage-kafka .*kafka-console-consumer" 2>/dev/null || true
    pkill -f "docker logs -f --tail 0 lineage-openlineage-collector" 2>/dev/null || true
    docker ps -q --filter "name=row-level-lineage-demo-duckdb-demo-run" | xargs -r docker rm -f >/dev/null 2>&1 || true
    # Only the windows THIS run opened (WINDOW_IDS). In each, stop the
    # recorder's own commands -- found with ps on that window's tty (macOS
    # pkill -t rejects these tty names) -- so Terminal has nothing to ask about
    # on close. Anything else still running there makes Terminal ask; never forced.
    local wid tty pids
    for wid in "${WINDOW_IDS[@]:-}"; do
      [[ -n "$wid" ]] || continue
      tty=$(osascript -e "tell application \"Terminal\" to tty of selected tab of window id ${wid}" 2>/dev/null)
      if [[ -n "$tty" ]]; then
        pids=$(ps -t "${tty#/dev/}" -o pid=,command= 2>/dev/null \
          | grep -E 'record-windows|docker (exec|logs|compose)|sed -u|sleep|run-stage' | grep -v grep | awk '{print $1}')
        # SIGKILL: bash defers TERM while its child runs, and the feed's loop
        # would just restart `docker logs`
        [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null && sleep 1
      fi
      osascript -e "tell application \"Terminal\" to close window id ${wid} saving no" >/dev/null 2>&1
    done
  fi
  exit "$code"
}
trap cleanup EXIT INT TERM

open_window() {  # open_window <command> -> window id (same pattern as record-talk3-demo.sh)
  osascript -e "tell application \"Terminal\" to do script \"$1\"" >/dev/null
  sleep 1
  osascript -e 'tell application "Terminal" to id of front window'
}
place_window() {  # place_window <wid> <font> <x1> <y1> <x2> <y2>; applied twice
  local script="
tell application \"Terminal\"
  set w to window id $1
  set current settings of selected tab of w to settings set \"${PROFILE}\"
  set font size of current settings of selected tab of w to $2
  set bounds of w to {$3, $4, $5, $6}
  set visible of w to true
end tell"
  osascript -e "$script" >/dev/null; sleep 0.5; osascript -e "$script" >/dev/null
  # Terminal can land a window off by the display's offset on a display that
  # extends above the main one: read where it went and correct by the difference
  local try x1 y1 x2 y2 dy ask=$4
  for try in 1 2 3; do
    sleep 0.5
    read -r x1 y1 x2 y2 <<< "$(bounds_of "$1")"
    dy=$(( $4 - y1 ))
    (( dy > -3 && dy < 3 )) && return 0
    ask=$(( ask + dy ))
    osascript -e "tell application \"Terminal\" to set bounds of window id $1 to {$3, ${ask}, $5, $(( ask + $6 - $4 ))}" >/dev/null
  done
  read -r x1 y1 x2 y2 <<< "$(bounds_of "$1")"
  log "window $1 at y ${y1} (asked for $4)"
}
bounds_of() { osascript -e "tell application \"Terminal\" to bounds of window id $1" | tr -d ','; }
run_in() {  # run_in <wid> <command>
  osascript -e "tell application \"Terminal\" to do script \"$2\" in window id $1" >/dev/null
}

read -r BROWSER_X1 BROWSER_Y1 BROWSER_X2 BROWSER_Y2 <<< "$(slot_bounds RB)"
browser_pid() { ps -axo pid=,command= | grep -- "--user-data-dir=${CHROME_DIR}" | grep -v -- "--type=" | grep -v grep | awk '{print $1}' | head -1; }
move_browser() {  # move_browser x1 y1 x2 y2: put the running Chrome window there, read where it went
  # retried until the frame matches: a move across displays sometimes only
  # half-lands (stage 2's MinIO window stayed parked on the main display)
  local try
  for try in 1 2 3 4; do
    move_browser_once "$@"
    (( ${#BROWSER_ACT[@]} == 4 )) \
      && (( ${BROWSER_ACT[0]} - $1 < 11 && $1 - ${BROWSER_ACT[0]} < 11 )) \
      && (( ${BROWSER_ACT[1]} - $2 < 41 && $2 - ${BROWSER_ACT[1]} < 41 )) \
      && (( ${BROWSER_ACT[2]} - $3 < 11 && $3 - ${BROWSER_ACT[2]} < 11 )) && return 0
    log "browser window landed at ${BROWSER_ACT[*]:-?}, wanted $* -- retrying (${try})"
    sleep 1
  done
  (( ${#BROWSER_ACT[@]} == 4 )) || BROWSER_ACT=("$@")
}
move_browser_once() {
  local pid frame
  BROWSER_ACT=()
  pid=$(browser_pid); [[ -n "$pid" ]] || { BROWSER_ACT=("$@"); return 0; }
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is ${pid})
    set w to window 1
    repeat with c in windows
      if subrole of c is \"AXStandardWindow\" then
        set w to c
        exit repeat
      end if
    end repeat
    set position of w to {$1, $2}
    set size of w to {$(( $3 - $1 )), $(( $4 - $2 ))}
  end tell" >/dev/null 2>&1 || log "couldn't move the browser window (Accessibility permission?)"
  MOVE_EPOCH="$(now)"   # when the window landed (record_stage gates its crop on this)
  sleep 1
  frame=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is ${pid})
    set w to window 1
    repeat with c in windows
      if subrole of c is \"AXStandardWindow\" then
        set w to c
        exit repeat
      end if
    end repeat
    set p to position of w
    set z to size of w
    return ((item 1 of p) as text) & \" \" & ((item 2 of p) as text) & \" \" & ((item 1 of z) as text) & \" \" & ((item 2 of z) as text)
  end tell" 2>/dev/null)
  if [[ -n "$frame" ]]; then
    read -r ax ay aw ah <<< "$frame"
    BROWSER_ACT=("$ax" "$ay" "$(( ax + aw ))" "$(( ay + ah ))")
  fi
}
browser_to() {  # browser_to <slot>: future/running Chrome window goes to that slot --
  # exactly over the terminal there, if one is (it replaces that view)
  read -r BROWSER_X1 BROWSER_Y1 BROWSER_X2 BROWSER_Y2 <<< "$(slot_bounds "$1")"
  local b x1 y1 x2 y2 ymin="" ymax=""
  for b in ${LAYOUT:-}; do
    read -r x1 y1 x2 y2 <<< "$(bounds_of "$(wid_of "${b%%:*}")")"
    [[ -z "$ymin" ]] || (( y1 < ymin )) && ymin=$y1
    [[ -z "$ymax" ]] || (( y2 > ymax )) && ymax=$y2
    if [[ "${b#*:}" == "$1" ]]; then BROWSER_X1=$x1; BROWSER_X2=$x2; fi
  done
  # vertically: from the terminals' actual top (Terminal lands windows higher
  # than asked) to a little below their bottom, so the browser's content --
  # drawn from the canvas top -- covers the full height of the clip
  [[ -n "$ymin" ]] && BROWSER_Y1=$ymin && BROWSER_Y2=$(( ymax + 12 ))
  move_browser "$BROWSER_X1" "$BROWSER_Y1" "$BROWSER_X2" "$BROWSER_Y2"
}
park_browser() { move_browser "${PARK_BOUNDS[@]}"; }
show_page() {  # show_page <url | polaris:/path>: (re)open the Chrome app window on it at the browser slot
  # Polaris console pages: open its login page, sign in, then navigate in-app
  # (its token lives in memory only, so a page load would log it out again)
  local polaris_path="" minio_path=""
  if [[ "$1" == minio:* ]]; then
    # MinIO console object browser: sign in once (session cookie), then open
    # the folder directly (its path, URL-encoded, is the route)
    minio_path="${1#minio:}"
    set -- "http://localhost:9001/browser/${MINIO_BUCKET}/$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${minio_path}")"
  fi
  if [[ "$1" == polaris:* ]]; then
    polaris_path="${1#polaris:}"
    set -- "http://localhost:${POLARIS_CONSOLE_PORT_HOST}/login"
  fi
  # Chrome already running: load the page in the same window. Relaunching
  # Chrome left the slot empty for seconds, showing the desktop in the video.
  if pgrep -f "user-data-dir=${CHROME_DIR}" >/dev/null; then
    move_browser "$BROWSER_X1" "$BROWSER_Y1" "$BROWSER_X2" "$BROWSER_Y2"
    if [[ -n "$polaris_path" && -n "${POLARIS_SIGNED_IN:-}" ]]; then
      # already signed in: in-app navigation (a reload would sign it out). Via
      # "/" first, so the page remounts and fetches fresh metadata -- going
      # straight to the route it's already on showed stage 1's stale schema
      cdp goto "/"
      sleep 1
      cdp goto "$polaris_path"
      sleep 2
      return 0
    fi
    POLARIS_SIGNED_IN=""
    if [[ -n "$minio_path" && -z "${MINIO_SIGNED_IN:-}" ]]; then
      cdp open "http://localhost:9001/login"; sleep 2
      cdp minio-login "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" && MINIO_SIGNED_IN=1
    fi
    cdp open "$1"
    sleep 3
    if [[ -n "$polaris_path" ]]; then
      cdp login "${POLARIS_CLIENT_ID}" "${POLARIS_CLIENT_SECRET}" "${CATALOG_SCOPE:-PRINCIPAL_ROLE:ALL}" && POLARIS_SIGNED_IN=1
      cdp goto "$polaris_path"
      sleep 2
    fi
    return 0
  fi
  # wait for the previous instance to exit fully: while it shuts down it still
  # holds the DevTools port, and the new instance would silently go without one
  if pkill -f "user-data-dir=${CHROME_DIR}" 2>/dev/null; then
    local i
    for i in $(seq 1 20); do
      pgrep -f "user-data-dir=${CHROME_DIR}" >/dev/null || break
      sleep 0.5
    done
  fi
  # password manager off, on every launch (an existing profile keeps whatever
  # it had): no "Save password?" bubble after the Polaris sign-in, and no
  # "Change your password" bubble after the MinIO one (minioadmin is on
  # Chrome's leaked-password list) -- that bubble became the process's
  # "window 1" and took every move meant for the page (take 103248)
  mkdir -p "${CHROME_DIR}/Default"
  python3 - "${CHROME_DIR}/Default/Preferences" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    prefs = json.load(open(path)) if os.path.exists(path) else {}
except ValueError:
    prefs = {}
prefs["credentials_enable_service"] = False
profile = prefs.setdefault("profile", {})
profile["password_manager_enabled"] = False
profile["password_manager_leak_detection"] = False
json.dump(prefs, open(path, "w"))
PY
  local launch_url="$1"
  [[ -n "$minio_path" ]] && launch_url="http://localhost:9001/login"
  open -na "Google Chrome" --args --user-data-dir="${CHROME_DIR}" --no-first-run --no-default-browser-check \
    --disable-features=PasswordLeakDetection,PasswordManagerOnboarding \
    --remote-debugging-port="${CDP_PORT}" \
    --app="${launch_url}" --window-position="${BROWSER_X1},${BROWSER_Y1}" \
    --window-size="$(( BROWSER_X2 - BROWSER_X1 )),$(( BROWSER_Y2 - BROWSER_Y1 ))"
  sleep 4
  # Chrome offsets --window-position on a display that extends above the main
  # one: move it into place with System Events (needs Accessibility
  # permission), then read where it really is
  move_browser "$BROWSER_X1" "$BROWSER_Y1" "$BROWSER_X2" "$BROWSER_Y2"
  if [[ -n "$minio_path" ]]; then
    cdp minio-login "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" && MINIO_SIGNED_IN=1
    cdp open "$1"
    sleep 3
  fi
  if [[ -n "$polaris_path" ]]; then
    cdp login "${POLARIS_CLIENT_ID}" "${POLARIS_CLIENT_SECRET}" "${CATALOG_SCOPE:-PRINCIPAL_ROLE:ALL}" && POLARIS_SIGNED_IN=1
    cdp goto "$polaris_path"
    sleep 2
  fi
}
BROWSER_ACT=("$BROWSER_X1" "$BROWSER_Y1" "$BROWSER_X2" "$BROWSER_Y2")
BLANK_PAGE='data:text/html,<body style="background:%23111"></body>'

# --- pages and queries per stage
catalog_table() {  # catalog_table <ns> <table> -> that table's page in the catalog UI (CATALOG_UI in .env)
  case "${CATALOG_UI:-lakekeeper}" in
    polaris) echo "polaris:/catalogs/${CATALOG_WAREHOUSE}/namespaces/$1/tables/$2" ;;
    lakekeeper) lakekeeper_table "$1" "$2" ;;
    *) echo "${BLANK_PAGE}" ;;
  esac
}
lakekeeper_table() {  # lakekeeper_table <ns> <table> -> its Lakekeeper UI page, or the blank page if the catalog isn't up
  local wid
  wid=$(curl -fsS "${CATALOG_URI_HOST}/v1/config?warehouse=${CATALOG_WAREHOUSE}" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("overrides",{}).get("prefix") or d["defaults"]["prefix"])' 2>/dev/null)
  if [[ -n "$wid" ]]; then echo "http://localhost:${LAKEKEEPER_PORT_HOST}/ui/warehouse/${wid}/namespace/$1/table/$2"; else echo "${BLANK_PAGE}"; fi
}
minio_table_data() {  # minio_table_data <ns> <table> -> the table's data/ folder in the MinIO console
  local loc
  loc=$(catalog_curl "$(catalog_table_url "$1" "$2")" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"]["location"])' 2>/dev/null)
  loc="${loc#s3://}"; loc="${loc#*/}"          # drop scheme and bucket
  echo "minio:${loc%/}/data/"
}
marquez_dataset() {  # marquez_dataset <table> -> Marquez lineage graph around that dataset
  local ns
  ns=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${OPENLINEAGE_DATASET_NAMESPACE}")
  echo "http://localhost:${MARQUEZ_WEB_PORT_HOST}/lineage/dataset/${ns}/$1"
}
set_query() { mkdir -p "$(dirname "${QUERY_FILE}")"; printf '%s\n' "$1" > "${QUERY_FILE}"; }

stage_setup() {  # stage_setup <N>: STAGE_ARGS, the SQL window's query, START/END pages
  STAGE_ARGS="$1"
  case "$1" in
    1) STAGE_TITLE="Stage 1 -- Ingest: row identity assigned at commit" ;;
    2) STAGE_TITLE="Stage 2 -- Update a row three times (deletion vectors)" ;;
    3) STAGE_TITLE="Stage 3 -- Schema evolution, with the stream still flowing" ;;
    4) STAGE_TITLE="Stage 4 -- Composable Lineage: lineage event -> exact rows" ;;
    5) STAGE_TITLE="Stage 5 -- Failure mode: equality-delete upsert" ;;
  esac
  # LAYOUT: role:slot for the windows this stage's slides need. BROWSER_SLOT:
  # where the browser shows (over a terminal's slot = it replaces that view);
  # BROWSER_WHEN: whole (from the start) or end (after the stage, START_PAGE unused)
  BROWSER_SLOT=""; BROWSER_WHEN=""
  case "$1" in
    1) LAYOUT="kafka:L sql:RT writer:RB"; BROWSER_SLOT=R; BROWSER_WHEN=end ;;    # slides 7, 8
    2) LAYOUT="writer:L sql:R"; BROWSER_SLOT=F; BROWSER_WHEN=end ;;               # slide 9
    3) LAYOUT="kafka:L writer:RT sql:RB"; BROWSER_SLOT=R; BROWSER_WHEN=end ;;    # slides 10, 12
    4) LAYOUT="feed:LT sql:LB"; BROWSER_SLOT=R; BROWSER_WHEN=whole ;;             # slides 18, 19
    5) LAYOUT="writer:L sql:R" ;;                                                 # slide 11
  esac
  END_SCROLL=""
  # Lakekeeper's table page shows Next row ID below the fold; Polaris's console doesn't show it
  LAKEKEEPER_SCROLL=""; [[ "${CATALOG_UI:-lakekeeper}" == lakekeeper ]] && LAKEKEEPER_SCROLL="Next row ID"
  # after stage 3's schema changes: Polaris's Schema section (current schema id,
  # channel + raw_payload variant); Lakekeeper keeps its Next row ID view
  SCHEMA_SCROLL="${LAKEKEEPER_SCROLL}"; [[ "${CATALOG_UI:-lakekeeper}" == polaris ]] && SCHEMA_SCROLL="Schema"
  case "$1" in
    1) set_query "-- bronze.events, newest rows: the Kafka JSON has no _row_id, the row does
SELECT _row_id, _last_updated_sequence_number AS seq, event_id, customer_id
FROM bronze.events ORDER BY _row_id DESC LIMIT 6;"
       START_PAGE="${BLANK_PAGE}"; END_PAGE="catalog_table bronze events"; END_SCROLL="${LAKEKEEPER_SCROLL}" ;;
    2) set_query "-- silver.customers, customer 9001: watch _row_id stay put
SELECT _row_id, _last_updated_sequence_number AS seq, customer_id, total_amount
FROM silver.customers WHERE customer_id = 9001;"
       # the files behind the MERGEs: Parquet data files + deletion vectors (*-deletes.puffin)
       START_PAGE="catalog_table bronze events"; END_PAGE="minio_table_data silver customers"; END_SCROLL="" ;;
    3) set_query "-- bronze.events, newest rows: the channel column appears when the sink evolves the table
SELECT * EXCLUDE (event_id, amount, ts) RENAME (_last_updated_sequence_number AS seq)
FROM bronze.events ORDER BY _row_id DESC LIMIT 6;"
       START_PAGE="catalog_table bronze events"; END_PAGE="catalog_table bronze events"; END_SCROLL="${SCHEMA_SCROLL}" ;;
    4) STAGE_ARGS="4 9001"
       set_query "-- silver.customers by last commit: the lineage event's sequenceNumber selects these rows
SELECT _row_id, _last_updated_sequence_number AS seq, customer_id, total_amount
FROM silver.customers ORDER BY seq DESC, customer_id;"
       START_PAGE="marquez_dataset silver.customers"; END_PAGE="marquez_dataset bronze.events" ;;
    5) set_query "-- equality delete + insert, customer 9500: watch _row_id change every round
SELECT _row_id, _last_updated_sequence_number AS seq, customer_id
FROM failure_demo.customers_equality_upsert WHERE customer_id = 9500;"
       START_PAGE="catalog_table silver customers"; END_PAGE="catalog_table failure_demo customers_equality_upsert"; END_SCROLL="${LAKEKEEPER_SCROLL}" ;;
  esac
}
resolve_page() { case "$1" in data:*) echo "$1" ;; *) $1 ;; esac; }
cdp() {  # cdp <command> <args...>: drive the browser window (demo/record-windows/cdp.mjs)
  local out
  out=$(node "${WIN_DIR}/cdp.mjs" "${CDP_PORT}" "$@" 2>&1 | tail -1)
  [[ "$out" == true ]] && return 0
  log "browser: '$1 ${2:-}' failed (${out:-no answer})"
  return 1
}
scroll_to() { cdp scroll "$1"; }

# --- reset first (not recorded)
if [[ -n "$RESET" ]]; then
  log "resetting the demo stack (not recorded)..."
  "${ROOT_DIR}/demo/run-stage.sh" reset > "${STATE_DIR}/reset.log" 2>&1 || { echo "[record] reset failed -- see ${STATE_DIR}/reset.log" >&2; exit 1; }
fi
stage_setup "${STAGES[0]}"

# --- open the windows (parked on the main display; each stage lays out its own)
log "opening the recorder's windows..."
WRITER_WID="$(open_window "cd '${ROOT_DIR}' && clear")"
WINDOW_IDS+=("$WRITER_WID")
KAFKA_WID="$(open_window "cd '${ROOT_DIR}' && bash demo/record-windows/kafka.sh")"
WINDOW_IDS+=("$KAFKA_WID")
SQL_WID="$(open_window "cd '${ROOT_DIR}' && bash demo/record-windows/sql.sh")"
WINDOW_IDS+=("$SQL_WID")
FEED_WID="$(open_window "cd '${ROOT_DIR}' && bash demo/record-windows/feed.sh")"
WINDOW_IDS+=("$FEED_WID")
wid_of() { case "$1" in writer) echo "$WRITER_WID" ;; kafka) echo "$KAFKA_WID" ;; sql) echo "$SQL_WID" ;; feed) echo "$FEED_WID" ;; esac; }
TITLE_KAFKA="Kafka topic '${KAFKA_TOPIC}' -- raw events as produced (no _row_id)"
TITLE_FEED="Lineage feed -- one OpenLineage event per Iceberg commit"

paint_header() {  # paint_header <wid> <title>: redraw demo/record-windows/header.sh's bar at the window's new size
  local tty rows cols
  tty=$(osascript -e "tell application \"Terminal\" to tty of selected tab of window id $1" 2>/dev/null)
  [[ -n "$tty" ]] || return 0
  read -r rows cols <<< "$(stty -f "$tty" size 2>/dev/null)"
  [[ -n "$rows" ]] || return 0
  printf '\033]0;%s\007\033[r\033[2J\033[3J\033[H\033[1;38;5;231;48;5;55m %-*.*s\033[0m\n\033[3;%dr\033[3;1H' \
    "$2" "$(( cols - 1 ))" "$(( cols - 1 ))" "$2" "$rows" > "$tty"
}

apply_layout() {  # apply_layout: this stage's windows into their slots, the rest parked
  local role wid slot font rt_y2="" lt_y2="" b
  for role in writer kafka sql feed; do
    wid=$(wid_of "$role"); slot=""
    for b in ${LAYOUT}; do [[ "${b%%:*}" == "$role" ]] && slot="${b#*:}"; done
    font="$FONT_SIZE"; [[ "$role" == writer ]] && font="$WRITER_FONT_SIZE"
    if [[ -z "$slot" ]]; then
      place_window "$wid" "$font" "${PARK_BOUNDS[@]}"
    fi
  done
  # top slots first, so RB can start below RT's actual bottom (Terminal snaps heights)
  for b in ${LAYOUT}; do
    role="${b%%:*}"; slot="${b#*:}"; [[ "$slot" == RB || "$slot" == LB ]] && continue
    font="$FONT_SIZE"; [[ "$role" == writer ]] && font="$WRITER_FONT_SIZE"
    place_window "$(wid_of "$role")" "$font" $(slot_bounds "$slot")
    [[ "$slot" == RT ]] && read -r _ _ _ rt_y2 <<< "$(bounds_of "$(wid_of "$role")")"
    [[ "$slot" == LT ]] && read -r _ _ _ lt_y2 <<< "$(bounds_of "$(wid_of "$role")")"
  done
  for b in ${LAYOUT}; do
    role="${b%%:*}"; slot="${b#*:}"; [[ "$slot" == RB || "$slot" == LB ]] || continue
    font="$FONT_SIZE"; [[ "$role" == writer ]] && font="$WRITER_FONT_SIZE"
    read -r x1 y1 x2 y2 <<< "$(slot_bounds "$slot")"
    [[ "$slot" == RB && -n "$rt_y2" ]] && y1=$(( rt_y2 + GAP ))
    [[ "$slot" == LB && -n "$lt_y2" ]] && y1=$(( lt_y2 + GAP ))
    place_window "$(wid_of "$role")" "$font" "$x1" "$y1" "$x2" "$y2"
  done
  # headers at the new sizes (the SQL window draws its own; the writer's comes with the stage command)
  for b in ${LAYOUT}; do
    case "${b%%:*}" in
      kafka) paint_header "$KAFKA_WID" "$TITLE_KAFKA" ;;
      feed) paint_header "$FEED_WID" "$TITLE_FEED" ;;
    esac
  done
}

# --- capture device (as in record-talk3-demo.sh): match the external display by aspect ratio
probe_screen() {  # probe_screen <avfoundation-index> -> "W H" of one captured frame, or nothing
  local png="${STATE_DIR}/probe-$1.png"
  ( ffmpeg -hide_banner -v error -f avfoundation -capture_cursor 0 -framerate 30 -pixel_format nv12 \
      -i "$1:none" -frames:v 1 -y "$png" > /dev/null 2>&1 & p=$!; sleep 8; kill "$p" 2>/dev/null ) 2>/dev/null
  [[ -f "$png" ]] && ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$png" | tr ',' ' '
}
SCREEN_DEV=""; SCALE=""
for dev in $(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
               | sed -n 's/.*\[\([0-9]*\)\] Capture screen [0-9]*.*/\1/p'); do
  read -r fw fh <<< "$(probe_screen "$dev")"
  [[ -z "${fw:-}" ]] && continue
  if python3 -c "import sys; sys.exit(0 if abs(${fw}/${fh} - ${EXT_W}/${EXT_H}) < 0.01 else 1)"; then
    SCREEN_DEV="$dev"; SCALE="$(python3 -c "print(round(${fw}/${EXT_W}, 4))")"
    log "captured display = avfoundation screen device ${dev} (${fw}x${fh}, scale ${SCALE})"
    break
  fi
done
[[ -n "$SCREEN_DEV" ]] || { echo "[record] couldn't identify the external display's capture device (Screen Recording permission?)" >&2; exit 1; }

# --- crops: each shown window's content area only (terminal title bar and
# rounded bottom corners off; the Chrome app window's title bar off), per stage
TITLE_BAR=32; BOTTOM_INSET=12; BROWSER_TITLE_BAR=38
join() { local IFS=,; echo "$*"; }
compute_crops() {  # compute_crops: CROP_* + canvas for this stage's LAYOUT (+ the browser's own slot)
  local b role slot wid x1 y1 x2 y2 top bottom cx cy cw ch rb_y1="" lb_y1="" i
  CROP_X=(); CROP_Y=(); CROP_W=(); CROP_H=(); CROP_ROLE=()
  local -a RX1=() RY1=() RX2=() RY2=() RTOP=() RSLOT=()
  for b in ${LAYOUT}; do
    role="${b%%:*}"; slot="${b#*:}"
    read -r x1 y1 x2 y2 <<< "$(bounds_of "$(wid_of "$role")")"
    RX1+=("$x1"); RY1+=("$y1"); RX2+=("$x2"); RY2+=("$y2"); RTOP+=("$TITLE_BAR"); RSLOT+=("$slot"); CROP_ROLE+=("$role")
    [[ "$slot" == RB ]] && rb_y1="$y1"
    [[ "$slot" == LB ]] && lb_y1="$y1"
  done
  CROP_ENABLE=(); CROP_TOP=()
  # the browser shown the whole stage (stage 4) gets its own crop; one that only
  # comes in at the end gets a time-gated crop later (add_browser_crop)
  if [[ "$BROWSER_WHEN" == whole ]]; then
    RX1+=("${BROWSER_ACT[0]}"); RY1+=("${BROWSER_ACT[1]}"); RX2+=("${BROWSER_ACT[2]}"); RY2+=("${BROWSER_ACT[3]}")
    RTOP+=("$BROWSER_TITLE_BAR"); RSLOT+=("$BROWSER_SLOT"); CROP_ROLE+=(browser)
    [[ "$BROWSER_SLOT" == RB ]] && rb_y1="${BROWSER_ACT[1]}"
  fi
  for i in "${!RX1[@]}"; do
    top=$(( RY1[i] + RTOP[i] )); bottom=$(( RY2[i] - BOTTOM_INSET ))
    # RT never runs into whatever sits in RB
    if [[ "${RSLOT[i]}" == RT && -n "$rb_y1" ]] && (( bottom > rb_y1 - 2 )); then bottom=$(( rb_y1 - 2 )); fi
    if [[ "${RSLOT[i]}" == LT && -n "$lb_y1" ]] && (( bottom > lb_y1 - 2 )); then bottom=$(( lb_y1 - 2 )); fi
    read -r cx cy cw ch <<< "$(python3 -c "
s=${SCALE}; ev=lambda v: int(v)//2*2
print(ev((${RX1[i]} - ${EXT_X})*s), ev((${top} - ${EXT_Y})*s), ev((${RX2[i]} - ${RX1[i]})*s), ev((${bottom} - ${top})*s))")"
    CROP_X+=("$cx"); CROP_Y+=("$cy"); CROP_W+=("$cw"); CROP_H+=("$ch"); CROP_ENABLE+=("")
    # the browser sits lower than the terminals (macOS keeps it below the
    # display's top): draw its content from the canvas top, so no strip of its
    # title bar or of the gap between panes shows above it
    if [[ "${CROP_ROLE[i]}" == browser ]]; then CROP_TOP+=(1); else CROP_TOP+=(""); fi
    log "${CROP_ROLE[i]} crop: ${cw}x${ch} at ${cx},${cy}"
  done
  read -r MIN_X MIN_Y CANVAS_W CANVAS_H <<< "$(python3 -c "
xs=[$(join "${CROP_X[@]}")]; ys=[$(join "${CROP_Y[@]}")]; ws=[$(join "${CROP_W[@]}")]; hs=[$(join "${CROP_H[@]}")]
x0=min(xs); y0=min(ys); ev=lambda v: (v+1)//2*2
print(x0, y0, ev(max(x+w for x,w in zip(xs,ws))-x0), ev(max(y+h for y,h in zip(ys,hs))-y0))")"
  log "canvas ${CANVAS_W}x${CANVAS_H}"
}
add_browser_crop() {  # add_browser_crop <from-sec>: the browser's current frame, shown from <from-sec> of the clip on
  local cx cy cw ch
  read -r cx cy cw ch <<< "$(python3 -c "
s=${SCALE}; ev=lambda v: int(v)//2*2
print(ev((${BROWSER_ACT[0]} - ${EXT_X})*s), ev((${BROWSER_ACT[1]} + ${BROWSER_TITLE_BAR} - ${EXT_Y})*s), ev((${BROWSER_ACT[2]} - ${BROWSER_ACT[0]})*s), ev((${BROWSER_ACT[3]} - ${BOTTOM_INSET} - ${BROWSER_ACT[1]} - ${BROWSER_TITLE_BAR})*s))")"
  # stay inside the canvas horizontally; vertically it's drawn from the canvas
  # top (see CROP_TOP below), so it can be at most the canvas height
  read -r cx cy cw ch <<< "$(python3 -c "
x0,y0,W,H=${MIN_X},${MIN_Y},${CANVAS_W},${CANVAS_H}; cx,cy,cw,ch=${cx},${cy},${cw},${ch}
ev=lambda v: int(v)//2*2
cx=max(cx,x0); cw=min(cw,x0+W-cx); ch=min(ch,H)
print(cx, cy, ev(cw), ev(ch))")"
  CROP_X+=("$cx"); CROP_Y+=("$cy"); CROP_W+=("$cw"); CROP_H+=("$ch"); CROP_ROLE+=(browser); CROP_ENABLE+=("$1"); CROP_TOP+=(1)
  log "browser crop: ${cw}x${ch} at ${cx},${cy}, from ${1}s"
}

# --- one clip per stage
record_stage() {  # record_stage <N>
  local n="$1" raw="${OUTPUT_DIR}/.raw-stage$1-${TIMESTAMP}.mp4" out="${OUTPUT_DIR}/stage$1-${TIMESTAMP}.mp4"
  local done_file="${STATE_DIR}/stage$1.done" pid stop raw_s out_s vf last i
  stage_setup "$n"
  apply_layout
  if [[ "$BROWSER_SLOT" ]]; then browser_to "$BROWSER_SLOT"; fi
  if [[ "$BROWSER_WHEN" == whole ]]; then
    show_page "$(resolve_page "${START_PAGE}")"
  else
    park_browser   # not part of this stage (yet)
  fi
  sleep 1
  compute_crops
  # park the pointer on the main display (-capture_cursor 0 isn't always honoured)
  osascript -l JavaScript -e "ObjC.import('CoreGraphics'); \$.CGWarpMouseCursorPosition(\$.CGPointMake($(( MAIN_W / 2 )), $(( MAIN_H / 2 ))))" >/dev/null 2>&1 || true
  log "stage ${n}: recording -> ${raw}"
  ffmpeg -hide_banner -v error -f avfoundation -capture_cursor 0 -framerate 30 -pixel_format nv12 \
    -i "${SCREEN_DEV}:none" -fps_mode cfr -r 30 -c:v libx264 -preset ultrafast -crf 16 -pix_fmt yuv420p \
    -y "$raw" < /dev/null > "${OUTPUT_DIR}/.ffmpeg-capture-stage${n}-${TIMESTAMP}.log" 2>&1 &
  pid=$!; RECORD_PIDS=("$pid")
  local rec_start; rec_start="$(now)"
  sleep "$LEAD_IN"
  rm -f "$done_file"
  # COMPOSE_PROGRESS=quiet: Compose's interactive progress display (image
  # builds) redraws the terminal and wiped the pinned header; quiet also drops
  # the "Container ... Created" noise from the video
  run_in "$WRITER_WID" "export COMPOSE_PROGRESS=quiet; bash demo/record-windows/header.sh '${STAGE_TITLE}'; demo/run-stage.sh ${STAGE_ARGS}; echo \$? > '${done_file}'"
  local waited=0
  until [[ -s "$done_file" ]]; do
    sleep 2; waited=$(( waited + 2 ))
    [[ "$waited" -ge 1200 ]] && { echo "[record] stage ${n} didn't finish within 20 min" >&2; exit 1; }
  done
  [[ "$(cat "$done_file")" == 0 ]] || { echo "[record] stage ${n} failed (exit $(cat "$done_file")) -- see the writer window" >&2; exit 1; }
  log "stage ${n} finished (${waited}s); final page + ${TAIL}s tail"
  if [[ -n "$BROWSER_SLOT" ]]; then
    # get the page ready OFF SCREEN (parked on the main display): sign in if
    # needed, load fresh data -- the catalog only has this stage's state now --
    # then move the finished page in. The audience never sees a login, a
    # loading or stale page, or the window split across the terminal panes.
    BROWSER_X1=${PARK_BOUNDS[0]}; BROWSER_Y1=${PARK_BOUNDS[1]}; BROWSER_X2=${PARK_BOUNDS[2]}; BROWSER_Y2=${PARK_BOUNDS[3]}
    show_page "$(resolve_page "${END_PAGE}")"
    browser_to "$BROWSER_SLOT"
    # in place: its crop takes over the right half from this moment (offset
    # from recording start minus the trimmed lead-in)
    [[ "$BROWSER_WHEN" == end ]] && add_browser_crop "$(python3 -c "print(round(${MOVE_EPOCH} - ${rec_start} - ${LEAD_IN}, 2))")"
  fi
  if [[ -n "${END_SCROLL}" && -n "$BROWSER_SLOT" ]]; then
    # top of the page (format, snapshot count) for half the tail, then scroll
    # to END_SCROLL (Lakekeeper: Next row ID) for the rest -- the last frame shows it
    sleep "$(python3 -c "print(${TAIL} / 2)")"
    scroll_to "${END_SCROLL}"
    sleep "$(python3 -c "print(${TAIL} / 2)")"
  else
    sleep "$TAIL"
  fi
  kill -INT "$pid" 2>/dev/null; stop="$(now)"; wait "$pid" 2>/dev/null; RECORD_PIDS=()
  sleep 1
  raw_s="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$raw")"
  out_s="$(python3 -c "print(round(${raw_s} - ${LEAD_IN}, 3))")"
  local n_crops="${#CROP_X[@]}" splits="" k
  for k in $(seq 0 $(( n_crops - 1 ))); do splits="${splits}[s${k}]"; done
  vf="color=c=black:s=${CANVAS_W}x${CANVAS_H}:r=30:d=${out_s}[bg];[0:v]split=${n_crops}${splits};"
  last="bg"
  for i in $(seq 0 $(( n_crops - 1 ))); do
    vf="${vf}[s${i}]crop=${CROP_W[i]}:${CROP_H[i]}:${CROP_X[i]}:${CROP_Y[i]}[v${i}];"
    local gate=""; [[ -n "${CROP_ENABLE[i]}" ]] && gate=":enable='gte(t,${CROP_ENABLE[i]})'"
    local oy=$(( CROP_Y[i] - MIN_Y )); [[ -n "${CROP_TOP[i]:-}" ]] && oy=0
    vf="${vf}[${last}][v${i}]overlay=$(( CROP_X[i] - MIN_X )):${oy}${gate}[c${i}];"
    last="c${i}"
  done
  vf="${vf%;}"
  log "stage ${n}: exporting ${out_s}s -> ${out}"
  if ffmpeg -y -ss "$LEAD_IN" -i "$raw" -filter_complex "$vf" -map "[${last}]" -t "$out_s" \
       -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p "$out" \
       < /dev/null > "${OUTPUT_DIR}/.ffmpeg-stage${n}-${TIMESTAMP}.log" 2>&1; then
    log "done: ${out}"
  else
    echo "[record] export failed -- see ${OUTPUT_DIR}/.ffmpeg-stage${n}-${TIMESTAMP}.log" >&2; exit 1
  fi
}

for n in "${STAGES[@]}"; do record_stage "$n"; done
log "all clips in ${OUTPUT_DIR} (raw captures kept as .raw-*)"
