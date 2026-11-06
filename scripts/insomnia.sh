#!/bin/bash
# insomnia: keep a MacBook running with the lid closed, with a thermal and
# battery watchdog that puts it back to sleep if it gets too hot or too empty.
# Fans and thermal throttling are never touched: macOS keeps managing them.

set -u

PIDFILE=/tmp/insomnia.pid
LOG=/tmp/insomnia-watchdog.log
# The running watchdog re-reads its stop time from here every check, so
# "insomnia set-hours" can change the limit of a session that is already on.
DEADLINE_FILE=/tmp/insomnia-deadline
SUDOERS_FILE=/etc/sudoers.d/insomnia
REMOTE_PIDFILE=/tmp/insomnia-remote.pid
REMOTE_LOG=/tmp/insomnia-remote.log
REMOTE_DIRFILE=/tmp/insomnia-remote.dir
REMOTE_STATE_DIR=/tmp/insomnia-remote.d
REMOTE_GUARD_PIDFILE=/tmp/insomnia-remote-guard.pid
LAST_DIR_FILE="$HOME/.config/insomnia/last-dir"
UPDATED_FILE="$HOME/.config/insomnia/just-updated"
HEAL_LABEL=com.oddproblems.insomnia.heal
HEAL_NOTIFIED=/tmp/insomnia-heal.notified
FAILED_LOG_DIR="$HOME/Library/Logs/Insomnia"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_SESSIONS_DIR="$HOME/Library/Application Support/Claude/claude-code-sessions"
SCHEDULE_RC_RULE=mcp__ccd_session_mgmt__set_remote_control
# Personal settings that survive updates: INSOMNIA_*=value lines in
# ~/.config/insomnia/config (read as plain values, never run as code). The
# environment wins over the file.
INSOMNIA_CONFIG="${INSOMNIA_CONFIG:-$HOME/.config/insomnia/config}"
if [ -f "$INSOMNIA_CONFIG" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      INSOMNIA_SCHEDULE_IGNORE|INSOMNIA_CLAUDE_BIN|INSOMNIA_REMOTE_SPAWN|INSOMNIA_REMOTE_MAX|INSOMNIA_REMOTE_MIN_BATTERY) ;;
      *) continue ;;
    esac
    [ -n "${!key+set}" ] && continue
    value="${value/#\~/$HOME}"
    export "$key=$value"
  done < "$INSOMNIA_CONFIG"
fi
SCHEDULE_IGNORE="${INSOMNIA_SCHEDULE_IGNORE-}"

INTERVAL=30
HOURS=0
MIN_BATTERY=20
MAX_BATT_TEMP=45
LOW_POWER=0
FOREGROUND=0
REMOTE_DIRS=""
REMOTE_MAX="${INSOMNIA_REMOTE_MAX:-8}"
REMOTE_SPAWN="${INSOMNIA_REMOTE_SPAWN:-worktree}"
REMOTE_MIN_BATTERY="${INSOMNIA_REMOTE_MIN_BATTERY:-20}"
TRIP_LEVELS="Heavy|Trapping|Sleeping|Serious|Critical"

CAFF_PID=""
ORIG_PM_BATT=""
ORIG_PM_AC=""
SLEEP_AFTER=0
STOP_PHONE=0
STOP_REASON="stopped"

usage() {
  cat <<'EOF'
Usage:
  insomnia on [options]   Keep the Mac awake with the lid closed.
                          Runs in the background; close any terminal you like.
  insomnia off [--all]    Restore normal sleep. Phone access (Remote Control) keeps
                          running so phone chats stay connected; --all stops it too.
  insomnia toggle         On if off, off if on.
  insomnia set-hours N    Change the time limit of the running session: stop N hours
                          from now (0 = no limit).
  insomnia status         Show sleep state, lid, power, battery temp, thermal pressure.
  insomnia state          Same as status, as key=value lines (for the menu bar app).
  insomnia recent-dirs [N]  Most recent folders Claude sessions ran in.
  insomnia remote-on DIR...|all [--remote-spawn M]
                          Only start phone access (no sudo), in each DIR or in
                          all recent Claude folders. Adds to folders already on.
  insomnia remote-off     Stop phone access in every folder.
  insomnia install-nopasswd    One-time: let insomnia switch without a password
                               (allows only its exact pmset/powermetrics commands).
  insomnia uninstall-nopasswd  Remove that rule again.
  insomnia nopasswd-status     Exit 0 if the rule is installed.
  insomnia heal           Restore normal sleep if it is disabled with no watchdog
                          running (after a crash, kill -9 or reboot mid-session).
  insomnia heal-agent install|uninstall|status
                          A login agent that runs "heal" at login and every minute.
  insomnia update [--check]  Get the latest Insomnia from GitHub (git pull in the
                          cloned folder) and rebuild the menu bar app if it changed.
                          --check only says whether an update is waiting
                          (--state says it as key=value lines, for the app).
  insomnia allow-schedules  Allow Claude to turn Remote Control on for scheduled-task
                          runs (adds one rule to ~/.claude/settings.json), so the
                          phone can open them. "status" lists recent runs still off.

Options for "on":
  --hours N          Stop after N hours (decimals ok), and stop phone access then too.
                     Default: no limit. Change it later with "insomnia set-hours".
  --min-battery P    On battery power, stop and sleep below P%. Default: 20.
  --max-temp C       Stop and sleep if battery temperature exceeds C °C. Default: 45.
  --low-power        Switch to Low Power Mode while running (less heat), restore after.
  --interval S       Watchdog check interval in seconds. Default: 30.
  --fg               Stay in the foreground; Ctrl+C restores normal sleep.
  --remote DIR|all   Also start Claude Remote Control in DIR, so the Claude phone app
                     (Code tab) or claude.ai/code can open existing sessions and create
                     new ones that run on this Mac. Repeat for more folders; "all"
                     uses the most recent Claude folders (up to INSOMNIA_REMOTE_MAX,
                     default 8; your home folder is skipped).
  --remote-spawn M   Where phone-created sessions run: worktree (default: each new chat in
                     its own worktree from origin/main, i.e. origin's default branch) or
                     same-dir (in the folder, on whatever branch it has checked out).
                     Folders that aren't git repos always use same-dir.

When a limit trips with the lid closed, the Mac is put to sleep immediately.
EOF
}

is_root() { [ "$(id -u)" = 0 ]; }

has_rule() { sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; }

priv() {
  if is_root; then "$@"; return; fi
  sudo -n "$@" 2>/dev/null && return 0
  [ -t 0 ] && sudo "$@"
}

log() {
  local line
  line="$(date '+%F %T') $*"
  echo "$line" >> "$LOG" 2>/dev/null
  [ -t 1 ] && echo "$line"
  return 0
}

batt_percent() { pmset -g batt | grep -Eo '[0-9]+%' | head -1 | tr -d %; }
on_battery() { pmset -g batt | head -1 | grep -q "Battery Power"; }
power_source() { if on_battery; then echo battery; else echo AC; fi; }

batt_temp() {
  ioreg -rn AppleSmartBattery | awk '$1=="\"Temperature\"" {printf "%.1f", $3/100; exit}'
}

lid_closed() { ioreg -r -k AppleClamshellState -d 4 | grep -q '"AppleClamshellState" = Yes'; }
lid_state() { if lid_closed; then echo closed; else echo open; fi; }

sleep_disabled() { pmset -g | awk '$1=="SleepDisabled" {print $2; exit}'; }

thermal_pressure() {
  local lvl
  if is_root; then
    lvl=$(powermetrics --samplers thermal -n 1 -i 1000 2>/dev/null | awk -F': ' '/pressure level/ {print $2; exit}')
  elif has_rule; then
    lvl=$(sudo -n /usr/bin/powermetrics --samplers thermal -n 1 -i 1000 2>/dev/null | awk -F': ' '/pressure level/ {print $2; exit}')
  else
    echo "n/a (needs sudo)"; return
  fi
  echo "${lvl:-unknown}"
}

powermode_for() {
  pmset -g custom | awk -v s="$1" '$0 ~ "^"s {f=1; next} /^[A-Za-z]/ {f=0} f && $1=="powermode" {print $2; exit}'
}

running_pid() {
  [ -f "$PIDFILE" ] || return 1
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null)
  # The pid must still be an insomnia watchdog ("insomnia _run" in the
  # background, "insomnia on --fg" in the foreground): after a crash or a
  # reboot the old number can be reused by an unrelated process.
  [ -n "$pid" ] && ps -o command= -p "$pid" 2>/dev/null | grep -Eq 'insomnia[^ /]* (_run|on)( |$)' && echo "$pid"
}

pid_owner() { ps -o user= -p "$1" 2>/dev/null | tr -d ' '; }

claude_bin() {
  if [ -n "${INSOMNIA_CLAUDE_BIN:-}" ] && [ -x "$INSOMNIA_CLAUDE_BIN" ]; then
    echo "$INSOMNIA_CLAUDE_BIN"
  elif command -v claude >/dev/null 2>&1; then
    command -v claude
  elif [ -x "$HOME/.local/bin/claude" ]; then
    echo "$HOME/.local/bin/claude"
  else
    return 1
  fi
}

# Phone access runs one `claude remote-control` server per folder, so the phone
# can open and start chats in each of them. Every server has a pid, dir and log
# file in $REMOTE_STATE_DIR, named by a short hash of the folder.
remote_key() { md5 -qs "$1" | cut -c1-12; }

# Live Remote Control servers, one "pid<TAB>dir" line each.
remote_list() {
  local f pid d
  for f in "$REMOTE_STATE_DIR"/*.pid "$REMOTE_PIDFILE"; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    { [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; } || continue
    if [ "$f" = "$REMOTE_PIDFILE" ]; then d=$(cat "$REMOTE_DIRFILE" 2>/dev/null); else d=$(cat "${f%.pid}.dir" 2>/dev/null); fi
    printf '%s\t%s\n' "$pid" "$d"
  done
}

remote_pid() {
  local line
  line=$(remote_list | head -1)
  [ -n "$line" ] && echo "${line%%	*}"
}

# The newest phone link printed by a live server.
remote_url() {
  local pid d
  remote_list | while IFS='	' read -r pid d; do
    if [ -f "$REMOTE_STATE_DIR/$(remote_key "$d").pid" ]; then echo "$REMOTE_STATE_DIR/$(remote_key "$d").log"; else echo "$REMOTE_LOG"; fi
  done | while IFS= read -r f; do
    sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$f" 2>/dev/null | grep -Eo 'https://claude\.ai/code[^ ]*' | tail -1
  done | tail -1
}

# The folders asked for with --remote (one per line); "all" expands to the most
# recent Claude folders. The home folder is skipped there: Remote Control never
# saves trust for it, so it cannot start unattended.
resolve_remote_dirs() {
  local entry d
  printf '%s\n' "$REMOTE_DIRS" | while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "$entry" = all ]; then
      cmd_recent_dirs "$REMOTE_MAX" | while IFS= read -r d; do
        [ "$d" = "$HOME" ] || echo "$d"
      done
    else
      d=$(cd "$entry" 2>/dev/null && pwd) || { echo "No such folder: $entry" >&2; continue; }
      echo "$d"
    fi
  done | awk 'NF && !seen[$0]++'
}

# A failed server's log outlives its cleanup, and a reboot (/tmp is wiped), so
# there is something to read or report. One file per folder; a later
# successful start there removes it.
failed_log_path() { echo "$FAILED_LOG_DIR/$(basename "$2")-$1.log"; }

keep_failed_log() {
  local key="$1" dir="$2" reason="$3"
  mkdir -p "$FAILED_LOG_DIR"
  {
    echo "$(date '+%F %T') phone access failed in $dir"
    echo "reason: $reason"
    echo
    sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$REMOTE_STATE_DIR/$key.log" 2>/dev/null
  } > "$(failed_log_path "$key" "$dir")"
}

start_remote() {
  local bin dirs dir key spawn computer started="" pending ok=0 failed=0 reason
  if on_battery && [ "$(batt_percent)" -lt "$REMOTE_MIN_BATTERY" ]; then
    echo "Battery is at $(batt_percent)%, below ${REMOTE_MIN_BATTERY}%. Plug in to start phone access." >&2
    return 1
  fi
  dirs=$(resolve_remote_dirs)
  [ -n "$dirs" ] || { echo "No folders to start phone access in." >&2; return 1; }
  bin=$(claude_bin) || { echo "claude CLI not found" >&2; return 1; }
  mkdir -p "$REMOTE_STATE_DIR"
  computer="$(scutil --get ComputerName 2>/dev/null || hostname)"
  while IFS= read -r dir; do
    key=$(remote_key "$dir")
    if remote_list | cut -f2 | grep -Fxq "$dir"; then
      echo "Phone access already on in $dir"; ok=$((ok + 1)); continue
    fi
    spawn="$REMOTE_SPAWN"
    if [ "$spawn" = worktree ] && ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      spawn=same-dir
    fi
    # In worktree mode every new phone chat gets its own worktree, which Claude
    # Code branches from origin/<default branch> (its worktree.baseRef "fresh"),
    # not from whatever branch the folder has checked out. The idle chat
    # Remote Control would otherwise open in the folder itself is skipped, since
    # that one would sit on the current branch.
    extra=()
    [ "$spawn" = worktree ] && extra=(--no-create-session-in-dir)
    echo "$dir" > "$REMOTE_STATE_DIR/$key.dir"
    ( cd "$dir" && trap '' HUP && exec "$bin" remote-control --name "$computer · $(basename "$dir")" --spawn "$spawn" ${extra[@]+"${extra[@]}"} ) </dev/null >"$REMOTE_STATE_DIR/$key.log" 2>&1 &
    echo $! > "$REMOTE_STATE_DIR/$key.pid"
    started="$started $key"
  done <<< "$dirs"

  for _ in $(seq 1 30); do
    pending=0
    for key in $started; do
      ps -p "$(cat "$REMOTE_STATE_DIR/$key.pid")" >/dev/null 2>&1 || continue
      grep -qE "Connected|Ready" "$REMOTE_STATE_DIR/$key.log" 2>/dev/null || pending=1
    done
    [ "$pending" = 0 ] && break
    sleep 1
  done

  for key in $started; do
    dir=$(cat "$REMOTE_STATE_DIR/$key.dir")
    if ps -p "$(cat "$REMOTE_STATE_DIR/$key.pid")" >/dev/null 2>&1 && grep -qE "Connected|Ready" "$REMOTE_STATE_DIR/$key.log"; then
      echo "Phone access on in $dir"; ok=$((ok + 1))
      rm -f "$(failed_log_path "$key" "$dir")"
    else
      reason=$(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$REMOTE_STATE_DIR/$key.log" 2>/dev/null | grep -v '^[[:space:]]*$' | awk '/^Error:/ {e=$0} {l=$0} END {print (e != "" ? e : l)}')
      reason=${reason:-no connection within 30 s}
      kill_tree "$(cat "$REMOTE_STATE_DIR/$key.pid")"
      keep_failed_log "$key" "$dir" "$reason"
      echo "Phone access failed in $dir: $reason" >&2
      echo "  Log: $(failed_log_path "$key" "$dir")" >&2
      rm -f "$REMOTE_STATE_DIR/$key".*
      failed=$((failed + 1))
    fi
  done

  if [ "$ok" = 0 ]; then
    echo "Remote Control failed to start, see the logs in $FAILED_LOG_DIR" >&2
    return 1
  fi
  if [ "$(printf '%s\n' "$dirs" | wc -l | tr -d ' ')" = 1 ]; then
    mkdir -p "$(dirname "$LAST_DIR_FILE")" && echo "$dirs" > "$LAST_DIR_FILE"
  fi
  if ! { [ -f "$REMOTE_GUARD_PIDFILE" ] && ps -p "$(cat "$REMOTE_GUARD_PIDFILE")" >/dev/null 2>&1; }; then
    ( trap '' HUP; exec "$0" _remote_guard ) </dev/null >>"$LOG" 2>&1 &
    echo $! > "$REMOTE_GUARD_PIDFILE"
  fi
  echo "Phone access is ON in $ok folder$([ "$ok" = 1 ] || echo s) (new phone sessions: $REMOTE_SPAWN)."
  echo "It stops by itself if the Mac is on battery below ${REMOTE_MIN_BATTERY}%."
  echo "Open the Claude app > Code on your phone, or: $(remote_url)"
}

kill_tree() {
  local child
  for child in $(pgrep -P "$1"); do
    kill_tree "$child"
  done
  kill -TERM "$1" 2>/dev/null
}

remote_guard() {
  local pct
  while remote_pid >/dev/null; do
    if on_battery; then
      pct=$(batt_percent)
      if [ -n "$pct" ] && [ "$pct" -lt "$REMOTE_MIN_BATTERY" ]; then
        log "phone access stopped: on battery at ${pct}%, below ${REMOTE_MIN_BATTERY}%"
        stop_remote
        break
      fi
    fi
    sleep 60
  done
  rm -f "$REMOTE_GUARD_PIDFILE"
}

stop_remote() {
  local pid
  remote_list | cut -f1 | while IFS= read -r pid; do
    kill_tree "$pid"
  done
  rm -f "$REMOTE_STATE_DIR"/*.pid "$REMOTE_STATE_DIR"/*.dir "$REMOTE_PIDFILE" "$REMOTE_DIRFILE"
}

cleanup() {
  trap - EXIT INT TERM HUP
  if [ -n "$CAFF_PID" ]; then
    { kill "$CAFF_PID"; wait "$CAFF_PID"; } 2>/dev/null
  fi
  priv /usr/bin/pmset -a disablesleep 0
  [ -n "$ORIG_PM_BATT" ] && priv /usr/bin/pmset -b powermode "$ORIG_PM_BATT"
  [ -n "$ORIG_PM_AC" ] && priv /usr/bin/pmset -c powermode "$ORIG_PM_AC"
  rm -f "$PIDFILE" "$DEADLINE_FILE"
  log "normal sleep restored ($STOP_REASON)"
  if [ "$STOP_PHONE" = 1 ] && remote_pid >/dev/null; then
    stop_remote >/dev/null 2>&1
    log "phone access stopped too"
  fi
  if [ "$SLEEP_AFTER" = 1 ] && lid_closed; then
    log "lid is closed, sleeping now"
    priv /usr/bin/pmset sleepnow >/dev/null
  fi
}

check_limits() {
  local temp pct lvl
  temp=$(batt_temp)
  if [ -n "$temp" ] && awk -v t="$temp" -v m="$MAX_BATT_TEMP" 'BEGIN{exit !(t>m)}'; then
    echo "battery temperature ${temp}°C above ${MAX_BATT_TEMP}°C"; return
  fi
  lvl=$(thermal_pressure)
  if echo "$lvl" | grep -Eqi "^($TRIP_LEVELS)$"; then
    echo "thermal pressure is $lvl"; return
  fi
  if on_battery; then
    pct=$(batt_percent)
    if [ -n "$pct" ] && [ "$pct" -lt "$MIN_BATTERY" ]; then
      echo "battery at ${pct}% below ${MIN_BATTERY}%"; return
    fi
  fi
}

parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --hours) HOURS="$2"; shift 2 ;;
      --min-battery) MIN_BATTERY="$2"; shift 2 ;;
      --max-temp) MAX_BATT_TEMP="$2"; shift 2 ;;
      --interval) INTERVAL="$2"; shift 2 ;;
      --low-power) LOW_POWER=1; shift ;;
      --fg) FOREGROUND=1; shift ;;
      --remote) REMOTE_DIRS="${REMOTE_DIRS:+$REMOTE_DIRS
}$2"; shift 2 ;;
      --remote-spawn) REMOTE_SPAWN="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
  done
}

cmd_on() {
  local orig=("$@") pid pct reason
  parse_opts "$@"
  if pid=$(running_pid); then
    echo "Already running (pid $pid). Use 'insomnia off' to stop it." >&2
    exit 1
  fi
  if on_battery; then
    pct=$(batt_percent)
    if [ -n "$pct" ] && [ "$pct" -lt "$MIN_BATTERY" ]; then
      echo "Battery is at ${pct}%, below the ${MIN_BATTERY}% minimum, so the watchdog would stop again right away. Plug in the charger, or start with a lower limit (insomnia on --min-battery N)." >&2
      exit 1
    fi
  fi
  if ! is_root && ! has_rule; then
    sudo -v || exit 1
    if [ -n "$REMOTE_DIRS" ]; then start_remote || exit 1; fi
    exec sudo "$0" on ${orig[@]+"${orig[@]}"}
  fi
  if ! is_root && [ -n "$REMOTE_DIRS" ]; then
    start_remote || exit 1
  fi
  [ -e "$LOG" ] || : > "$LOG"
  is_root && chmod 666 "$LOG" 2>/dev/null
  if [ "$FOREGROUND" = 1 ]; then
    run_watchdog
  else
    ( trap '' HUP; exec "$0" _run ${orig[@]+"${orig[@]}"} ) </dev/null >>"$LOG" 2>&1 &
    sleep 1
    if pid=$(running_pid); then
      echo "Insomnia is ON (pid $pid). Close the lid whenever you like."
      echo "Turn it off with: insomnia off   (log: $LOG)"
    else
      stop_remote
      reason=$(tail -n 5 "$LOG" 2>/dev/null | sed -n 's/.*normal sleep restored (\(.*\))$/\1/p' | tail -1)
      echo "Failed to start${reason:+: $reason}. See $LOG" >&2
      exit 1
    fi
  fi
}

run_watchdog() {
  echo $$ > "$PIDFILE"
  is_root && chmod 644 "$PIDFILE"
  trap cleanup EXIT
  trap 'STOP_REASON="interrupted"; exit 130' INT
  trap 'STOP_REASON="stopped by insomnia off"; exit 0' TERM
  trap 'STOP_REASON="terminal closed"; exit 0' HUP

  if [ "$LOW_POWER" = 1 ]; then
    ORIG_PM_BATT=$(powermode_for "Battery Power")
    ORIG_PM_AC=$(powermode_for "AC Power")
    priv /usr/bin/pmset -a powermode 1
  fi

  if ! priv /usr/bin/pmset -a disablesleep 1; then
    STOP_REASON="could not disable sleep (no admin rights)"; exit 1
  fi
  caffeinate -ims -w $$ &
  CAFF_PID=$!

  local start deadline now reason beat=0
  start=$(date +%s)
  deadline=0
  if [ "$HOURS" != 0 ]; then
    deadline=$(awk -v s="$start" -v h="$HOURS" 'BEGIN{printf "%d", s + h*3600}')
  fi
  echo "$deadline" > "$DEADLINE_FILE"
  is_root && chmod 666 "$DEADLINE_FILE"

  log "insomnia ON (power=$(power_source), battery=$(batt_percent)%, temp=$(batt_temp)°C, thermal=$(thermal_pressure), limit=${HOURS}h, min-battery=${MIN_BATTERY}%, max-temp=${MAX_BATT_TEMP}°C, low-power=$LOW_POWER)"
  [ -t 1 ] && echo "You can close the lid now. Ctrl+C here, or 'insomnia off' from any terminal, restores normal sleep."

  while :; do
    reason=$(check_limits)
    if [ -n "$reason" ]; then
      STOP_REASON="$reason"; SLEEP_AFTER=1; exit 0
    fi
    now=$(date +%s)
    deadline=$(cat "$DEADLINE_FILE" 2>/dev/null)
    case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
    if [ "$deadline" -gt 0 ] && [ "$now" -ge "$deadline" ]; then
      STOP_REASON="time limit reached"; SLEEP_AFTER=1; STOP_PHONE=1; exit 0
    fi
    if [ "$(sleep_disabled)" != 1 ]; then
      priv /usr/bin/pmset -a disablesleep 1
    fi
    beat=$((beat + INTERVAL))
    if [ "$beat" -ge 600 ]; then
      beat=0
      log "heartbeat: lid=$(lid_state) power=$(power_source) battery=$(batt_percent)% temp=$(batt_temp)°C thermal=$(thermal_pressure)"
    fi
    sleep "$INTERVAL" & wait $!
  done
}

# The running session's stop time (epoch seconds, 0 = no limit). A watchdog
# from before set-hours has no deadline file, so work it out from its start
# time and --hours argument instead.
# When the running session started (epoch seconds).
session_start() {
  local pid
  pid=$(running_pid) || return 0
  date -j -f "%a %b %d %T %Y" "$(ps -o lstart= -p "$pid" 2>/dev/null | awk '{print $1, $2, $3, $4, $5}')" +%s 2>/dev/null
}

session_deadline() {
  local pid line start h
  if [ -f "$DEADLINE_FILE" ]; then cat "$DEADLINE_FILE"; return; fi
  pid=$(running_pid) || return 0
  line=$(ps -o lstart= -o args= -p "$pid" 2>/dev/null) || return 0
  start=$(date -j -f "%a %b %d %T %Y" "$(echo "$line" | awk '{print $1, $2, $3, $4, $5}')" +%s 2>/dev/null) || return 0
  h=$(echo "$line" | sed -n 's/.*--hours \([0-9.]*\).*/\1/p')
  if [ -z "$h" ] || [ "$h" = 0 ]; then echo 0; return; fi
  awk -v s="$start" -v h="$h" 'BEGIN{printf "%d", s + h*3600}'
}

cmd_set_hours() {
  local h="${1:-}" deadline=0
  case "$h" in ''|*[!0-9.]*) echo "Usage: insomnia set-hours N   (0 = no limit)" >&2; return 2 ;; esac
  if ! running_pid >/dev/null; then
    echo "Insomnia is off; give the limit when turning it on: insomnia on --hours $h" >&2
    return 1
  fi
  if [ ! -f "$DEADLINE_FILE" ]; then
    echo "This session was started by an older Insomnia, which can't change its limit. Turn Insomnia off and on again to use the new one." >&2
    return 1
  fi
  if awk -v h="$h" 'BEGIN{exit !(h > 0)}'; then
    deadline=$(awk -v s="$(date +%s)" -v h="$h" 'BEGIN{printf "%d", s + h*3600}')
  fi
  echo "$deadline" > "$DEADLINE_FILE" || return 1
  if [ "$deadline" = 0 ]; then
    log "time limit removed"; echo "No time limit now."
  else
    log "time limit set: stops at $(date -r "$deadline" '+%H:%M')"
    echo "Stops at $(date -r "$deadline" '+%H:%M')."
  fi
}

cmd_off() {
  local pid all=0
  [ "${1:-}" = "--all" ] && all=1
  pid=$(running_pid)
  if ! is_root; then
    if ! has_rule || { [ -n "$pid" ] && [ "$(pid_owner "$pid")" = root ]; }; then
      exec sudo "$0" off "$@"
    fi
  fi
  if [ -n "$pid" ]; then
    kill -TERM "$pid"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      ps -p "$pid" >/dev/null 2>&1 || break
      sleep 0.5
    done
  fi
  priv /usr/bin/pmset -a disablesleep 0
  rm -f "$PIDFILE" 2>/dev/null
  if [ "$all" = 1 ]; then
    stop_remote
    echo "Normal sleep restored. Remote Control stopped."
  elif remote_pid >/dev/null; then
    echo "Normal sleep restored. Remote Control still running, so phone chats stay connected while the Mac is awake (stop it with: insomnia remote-off)."
  else
    echo "Normal sleep restored."
  fi
}

# Crash-proof restore: if sleep is disabled but no watchdog is alive (kill -9,
# crash, power loss, a reboot during a session), switch normal sleep back on.
# Run by the heal agent at login and every minute; safe to run any time.
cmd_heal() {
  [ "$(sleep_disabled)" = 1 ] || { rm -f "$HEAL_NOTIFIED"; return 0; }
  running_pid >/dev/null && return 0
  # A session that is starting or stopping right now owns the setting; look again.
  sleep 3
  [ "$(sleep_disabled)" = 1 ] || return 0
  running_pid >/dev/null && return 0
  if priv /usr/bin/pmset -a disablesleep 0; then
    rm -f "$PIDFILE" "$HEAL_NOTIFIED" 2>/dev/null
    log "heal: sleep was disabled with no watchdog running, normal sleep restored"
    echo "Sleep was disabled with no watchdog running. Normal sleep restored."
    if lid_closed; then
      log "heal: lid is closed, sleeping now"
      priv /usr/bin/pmset sleepnow >/dev/null
    fi
    return 0
  fi
  log "heal: sleep is disabled with no watchdog running, but restoring needs admin rights (insomnia install-nopasswd)"
  echo "Sleep is disabled with no watchdog running. Run 'insomnia off' (or install-nopasswd so this fixes itself)." >&2
  if [ ! -f "$HEAL_NOTIFIED" ]; then
    touch "$HEAL_NOTIFIED"
    /usr/bin/osascript -e 'display notification "Sleep is disabled but no watchdog is running. Run: insomnia off" with title "Insomnia"' >/dev/null 2>&1
  fi
  return 1
}

heal_agent_path() { echo "$HOME/Library/LaunchAgents/$HEAL_LABEL.plist"; }

cmd_heal_agent() {
  local plist script
  plist=$(heal_agent_path)
  case "${1:-status}" in
    install)
      script=$(realpath "$0")
      mkdir -p "$(dirname "$plist")"
      cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$HEAL_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$script</string><string>heal</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
PLIST
      launchctl bootout "gui/$(id -u)/$HEAL_LABEL" 2>/dev/null
      launchctl bootstrap "gui/$(id -u)" "$plist" && echo "Heal agent installed: restores normal sleep within a minute if a session dies without cleaning up."
      has_rule || echo "Note: without 'insomnia install-nopasswd' it can only notify you, not restore sleep itself."
      ;;
    uninstall)
      launchctl bootout "gui/$(id -u)/$HEAL_LABEL" 2>/dev/null
      rm -f "$plist"
      echo "Heal agent removed."
      ;;
    status)
      launchctl print "gui/$(id -u)/$HEAL_LABEL" >/dev/null 2>&1
      ;;
    *) echo "Usage: insomnia heal-agent install|uninstall|status" >&2; return 2 ;;
  esac
}

# The cloned folder this command runs from (the installer links ~/.local/bin/insomnia into it).
insomnia_repo() {
  local self
  self=$(realpath "$0" 2>/dev/null) || self="$0"
  (cd "$(dirname "$self")/.." && pwd)
}

# True when the folder is its own clone of Insomnia that tracks a remote branch,
# not a copy that happens to sit inside some other git repo.
is_insomnia_clone() {
  local repo="$1" top
  top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$(cd "$top" && pwd -P)" = "$(cd "$repo" && pwd -P)" ] || return 1
  [ -f "$repo/scripts/insomnia.sh" ] && [ -f "$repo/menubar/main.swift" ] || return 1
  git -C "$repo" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1
}

# key=value lines for the menu bar app. Fetches from GitHub, so it takes a moment.
update_state() {
  local repo
  repo=$(insomnia_repo)
  if ! is_insomnia_clone "$repo"; then
    echo "managed=0"
    return 0
  fi
  echo "managed=1"
  echo "repo=$repo"
  git -C "$repo" log -1 --format='current=%h%ncurrent_date=%cd' --date=short HEAD
  if ! git -C "$repo" fetch --quiet 2>/dev/null; then
    echo "offline=1"
    return 0
  fi
  git -C "$repo" log -1 --format='latest=%h%nlatest_date=%cd' --date=short '@{u}'
  echo "behind=$(git -C "$repo" rev-list --count 'HEAD..@{u}')"
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ] || echo "local_changes=1"
  git -C "$repo" log --format='change=%s' 'HEAD..@{u}' | head -n 8
}

# Rebuild the menu bar app when its code changed since the commit it was built
# from (stamped by build.sh; $2 stands in for apps built before the stamp existed).
rebuild_app_if_behind() {
  local repo="$1" fallback="$2" app="$HOME/Applications/Insomnia.app" built
  [ -d "$app" ] || return 0
  built=$(cat "$app/Contents/Resources/built-from" 2>/dev/null)
  git -C "$repo" cat-file -e "${built:-none}^{commit}" 2>/dev/null || built=$fallback
  git -C "$repo" diff --quiet "$built" HEAD -- menubar && return 0
  echo "Rebuilding the menu bar app..."
  "$repo/menubar/build.sh" || { echo "The app didn't build. The command is updated; run $repo/menubar/build.sh to see why." >&2; return 1; }
}

cmd_update() {
  local check=0 repo old behind
  case "${1:-}" in
    --check) check=1 ;;
    --state) update_state; return ;;
    "") ;;
    *) echo "Usage: insomnia update [--check]" >&2; return 2 ;;
  esac
  repo=$(insomnia_repo)
  if ! is_insomnia_clone "$repo"; then
    echo "$repo isn't a git clone that tracks GitHub, so it can't update itself." >&2
    echo "Reinstall: git clone https://github.com/ArtemKorchunov/insomnia.git ~/insomnia && ~/insomnia/install.sh" >&2
    return 1
  fi
  git -C "$repo" fetch --quiet || { echo "Couldn't reach GitHub. Check the connection and try again." >&2; return 1; }
  behind=$(git -C "$repo" rev-list --count 'HEAD..@{u}')
  if [ "$behind" = 0 ]; then
    [ "$check" = 1 ] || rebuild_app_if_behind "$repo" HEAD || return 1
    echo "Insomnia is up to date ($(git -C "$repo" log -1 --format='%h from %cd' --date=short))."
    return 0
  fi
  if [ "$check" = 1 ]; then
    echo "$behind update(s) waiting. Run: insomnia update"
    git -C "$repo" log --format='  - %s' 'HEAD..@{u}'
    return 0
  fi
  if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
    echo "You changed files in $repo. Commit or stash them (git -C $repo stash), then run insomnia update again." >&2
    return 1
  fi
  old=$(git -C "$repo" rev-parse HEAD)
  if ! git -C "$repo" merge --ff-only --quiet '@{u}'; then
    echo "Your copy in $repo has commits of its own, so it can't fast-forward. Run git -C $repo pull and sort it out there." >&2
    return 1
  fi
  echo "Updated Insomnia to $(git -C "$repo" log -1 --format=%h). New:"
  git -C "$repo" log --format='  - %s' "$old..HEAD"
  # The menu bar app reads this once (after it restarts, if it was rebuilt) to say
  # the update landed and what's new.
  mkdir -p "$(dirname "$UPDATED_FILE")"
  git -C "$repo" log --format='%s' "$old..HEAD" > "$UPDATED_FILE"
  rebuild_app_if_behind "$repo" "$old" || return 1
  if running_pid >/dev/null; then
    echo "The session that's on keeps running as it was; the update applies from the next start."
  fi
}

cmd_install_nopasswd() {
  local user tmp
  user="${SUDO_USER:-$USER}"
  tmp=$(mktemp)
  cat > "$tmp" <<RULE
$user ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow, /usr/bin/pmset -a powermode 1, /usr/bin/pmset -b powermode 0, /usr/bin/pmset -b powermode 1, /usr/bin/pmset -b powermode 2, /usr/bin/pmset -c powermode 0, /usr/bin/pmset -c powermode 1, /usr/bin/pmset -c powermode 2, /usr/bin/powermetrics --samplers thermal -n 1 -i 1000
RULE
  if ! visudo -cf "$tmp" >/dev/null; then
    echo "Generated rule failed validation, nothing installed." >&2
    rm -f "$tmp"; exit 1
  fi
  echo "Installing $SUDOERS_FILE:"
  cat "$tmp"
  sudo install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_FILE" && echo "Done. insomnia on/off no longer asks for a password."
  rm -f "$tmp"
}

# Scheduled-task runs in the Claude app start with Remote Control off, so the
# phone can't open them. Only the app can switch it on, through the tool this
# rule allows (a scheduled task of your own calls it). Insomnia only reads the
# app's session files to say which recent runs are still off.
schedule_rc_rule() { grep -q "\"$SCHEDULE_RC_RULE\"" "$CLAUDE_SETTINGS" 2>/dev/null; }

# Task ids of unarchived scheduled runs from the last 3 days that are still off,
# one line per run.
schedule_runs_off() {
  local f t
  [ -d "$CLAUDE_SESSIONS_DIR" ] || return 0
  find "$CLAUDE_SESSIONS_DIR" -name 'local_*.json' -mtime -3 -print0 2>/dev/null |
    xargs -0 grep -l '"scheduledTaskId":"' 2>/dev/null |
    while IFS= read -r f; do
      grep -q '"remoteControlUserEnabled":true' "$f" && continue
      grep -q '"isArchived":true' "$f" && continue
      t=$(grep -o '"scheduledTaskId":"[^"]*"' "$f" | head -1 | cut -d'"' -f4)
      case " $SCHEDULE_IGNORE " in *" $t "*) continue ;; esac
      echo "$t"
    done
}

cmd_allow_schedules() {
  if schedule_rc_rule; then echo "Already allowed in $CLAUDE_SETTINGS."; return 0; fi
  [ -f "$CLAUDE_SETTINGS" ] || { echo "No $CLAUDE_SETTINGS found." >&2; return 1; }
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
  python3 - "$CLAUDE_SETTINGS" "$SCHEDULE_RC_RULE" <<'PY' || return 1
import json, os, sys
path, rule = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d.setdefault("permissions", {}).setdefault("allow", []).append(rule)
with open(path + ".tmp", "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")
json.load(open(path + ".tmp"))
os.replace(path + ".tmp", path)
PY
  echo "Allowed $SCHEDULE_RC_RULE in $CLAUDE_SETTINGS (backup kept next to it)."
  echo "Something still has to call it for each run, such as a scheduled task of your own."
}

cmd_status() {
  local pid sd f off
  sd=$(sleep_disabled)
  if pid=$(running_pid); then
    echo "Session:          running (pid $pid)"
    f=$(session_deadline)
    case "$f" in 0) echo "Stops:            no time limit" ;;
      ''|*[!0-9]*) echo "Stops:            not known" ;;
      *) if [ -f "$DEADLINE_FILE" ]; then echo "Stops:            at $(date -r "$f" '+%H:%M') (and phone access with it)"
         else echo "Stops:            at $(date -r "$f" '+%H:%M') (older session: limit fixed, phone access stays on)"; fi ;; esac
  else
    echo "Session:          not running"
  fi
  echo "Sleep disabled:   ${sd:-0}"
  if [ "${sd:-0}" = 1 ] && ! running_pid >/dev/null; then
    echo "WARNING: sleep is disabled but no watchdog is running. Run 'insomnia off' (the heal agent fixes this within a minute)."
  fi
  echo "Lid:              $(lid_state)"
  echo "Power source:     $(power_source)"
  echo "Battery:          $(batt_percent)%"
  echo "Battery temp:     $(batt_temp)°C"
  echo "Thermal pressure: $(thermal_pressure)"
  if has_rule; then echo "No-password rule: installed"; else echo "No-password rule: not installed (insomnia install-nopasswd)"; fi
  if remote_pid >/dev/null; then
    echo "Remote Control:   running in $(remote_list | wc -l | tr -d ' ') folder(s) $(remote_url)"
    remote_list | while IFS='	' read -r pid d; do echo "                  $d (pid $pid)"; done
  else
    echo "Remote Control:   not running"
  fi
  for f in "$FAILED_LOG_DIR"/*.log; do
    [ "$(basename "$f")" = update.log ] && continue   # the menu bar app's update log
    [ -f "$f" ] && echo "Failed phone log: $f"
  done
  if schedule_rc_rule; then
    echo "Scheduled runs:   phone switch allowed"
  else
    echo "Scheduled runs:   phone switch not allowed (insomnia allow-schedules)"
  fi
  off=$(schedule_runs_off | sort | uniq -c | sort -rn)
  if [ -n "$off" ]; then
    echo "                  $(echo "$off" | awk '{n += $1} END {print n}') recent run(s) the phone can't open:" \
      "$(echo "$off" | awk '{printf "%s%s (%s)", s, $2, $1; s = ", "}')"
  fi
  echo "Log:              $LOG"
}

cmd_state() {
  local pid sd
  sd=$(sleep_disabled)
  if running_pid >/dev/null; then
    echo "running=1"
    echo "deadline=$(session_deadline)"
    [ -f "$DEADLINE_FILE" ] || echo "deadline_fixed=1"
    echo "started=$(session_start)"
  else
    echo "running=0"
    echo "last_stop=$(tail -n 30 "$LOG" 2>/dev/null | sed -n 's/^[0-9-]* \([0-9][0-9]:[0-9][0-9]\):[0-9][0-9] normal sleep restored (\(.*\))$/\1|\2/p' | tail -1)"
  fi
  echo "sleep_disabled=${sd:-0}"
  if remote_pid >/dev/null; then
    echo "remote=1"
    echo "remote_count=$(remote_list | wc -l | tr -d ' ')"
    echo "remote_dir=$(remote_list | head -1 | cut -f2)"
    echo "remote_dirs=$(remote_list | cut -f2 | paste -sd '|' -)"
    echo "remote_url=$(remote_url)"
  else
    echo "remote=0"
  fi
  echo "lid=$(lid_state)"
  echo "power=$(power_source)"
  echo "battery=$(batt_percent)"
  echo "temp=$(batt_temp)"
  # macOS's own time-to-empty estimate, in minutes (empty while charging or still estimating).
  echo "batt_minutes=$(pmset -g batt 2>/dev/null | sed -n 's/.*discharging; \([0-9]*\):\([0-9][0-9]\) remaining.*/\1 \2/p' | awk '{print $1*60+$2}')"
  if has_rule; then echo "nopasswd=1"; else echo "nopasswd=0"; fi
  echo "min_battery=$MIN_BATTERY"
  echo "max_temp=$MAX_BATT_TEMP"
}

cmd_recent_dirs() {
  local n="${1:-8}" proj f d
  {
    [ -f "$LAST_DIR_FILE" ] && cat "$LAST_DIR_FILE"
    ls -t "$HOME/.claude/projects" 2>/dev/null | head -40 | while IFS= read -r proj; do
      f=$(ls -t "$HOME/.claude/projects/$proj"/*.jsonl 2>/dev/null | head -1)
      [ -n "$f" ] && grep -m1 -o '"cwd":"[^"]*"' "$f" | sed 's/^"cwd":"//; s/"$//'
    done
  } | awk 'NF && !seen[$0]++' | while IFS= read -r d; do
    case "$d" in */.claude/worktrees/*|*/Library/*|/tmp/*|/private/*) continue ;; esac
    [ -d "$d" ] && echo "$d"
  done | head -n "$n"
}

case "${1:-}" in
  on) shift; cmd_on "$@" ;;
  _run) shift; parse_opts "$@"; run_watchdog ;;
  _remote_guard) remote_guard ;;
  off) shift; cmd_off "$@" ;;
  toggle)
    shift
    if running_pid >/dev/null; then cmd_off; else cmd_on "$@"; fi ;;
  status) cmd_status ;;
  set-hours) cmd_set_hours "${2:-}" ;;
  state) cmd_state ;;
  recent-dirs) cmd_recent_dirs "${2:-8}" ;;
  remote-on)
    shift
    while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
      REMOTE_DIRS="${REMOTE_DIRS:+$REMOTE_DIRS
}$1"; shift
    done
    [ -n "$REMOTE_DIRS" ] || { echo "Usage: insomnia remote-on DIR... | all" >&2; exit 2; }
    parse_opts "$@"; start_remote ;;
  remote-off) stop_remote; echo "Remote Control stopped." ;;
  install-nopasswd) cmd_install_nopasswd ;;
  uninstall-nopasswd) sudo rm -f "$SUDOERS_FILE" && echo "Removed $SUDOERS_FILE." ;;
  nopasswd-status) has_rule ;;
  heal) cmd_heal ;;
  heal-agent) cmd_heal_agent "${2:-status}" ;;
  allow-schedules) cmd_allow_schedules ;;
  update) cmd_update "${2:-}" ;;
  -h|--help|help|"") usage ;;
  *) echo "Unknown command: $1" >&2; usage; exit 2 ;;
esac; exit
