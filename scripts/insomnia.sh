#!/bin/bash
# insomnia: keep a MacBook running with the lid closed, with a thermal and
# battery watchdog that puts it back to sleep if it gets too hot or too empty.
# Fans and thermal throttling are never touched: macOS keeps managing them.

set -u

PIDFILE=/tmp/insomnia.pid
LOG=/tmp/insomnia-watchdog.log
SUDOERS_FILE=/etc/sudoers.d/insomnia
REMOTE_PIDFILE=/tmp/insomnia-remote.pid
REMOTE_LOG=/tmp/insomnia-remote.log
REMOTE_DIRFILE=/tmp/insomnia-remote.dir
LAST_DIR_FILE="$HOME/.config/insomnia/last-dir"
HEAL_LABEL=com.oddproblems.insomnia.heal
HEAL_NOTIFIED=/tmp/insomnia-heal.notified

INTERVAL=30
HOURS=0
MIN_BATTERY=20
MAX_BATT_TEMP=45
LOW_POWER=0
FOREGROUND=0
REMOTE_DIR=""
REMOTE_SPAWN="same-dir"
REMOTE_MIN_BATTERY="${INSOMNIA_REMOTE_MIN_BATTERY:-20}"
TRIP_LEVELS="Heavy|Trapping|Sleeping|Serious|Critical"

CAFF_PID=""
ORIG_PM_BATT=""
ORIG_PM_AC=""
SLEEP_AFTER=0
STOP_REASON="stopped"

usage() {
  cat <<'EOF'
Usage:
  insomnia on [options]   Keep the Mac awake with the lid closed.
                          Runs in the background; close any terminal you like.
  insomnia off [--all]    Restore normal sleep. Phone access (Remote Control) keeps
                          running so phone chats stay connected; --all stops it too.
  insomnia toggle         On if off, off if on.
  insomnia status         Show sleep state, lid, power, battery temp, thermal pressure.
  insomnia state          Same as status, as key=value lines (for the menu bar app).
  insomnia recent-dirs [N]  Most recent folders Claude sessions ran in.
  insomnia remote-on DIR [--remote-spawn M]   Only start Remote Control (no sudo).
  insomnia remote-off     Only stop Remote Control.
  insomnia install-nopasswd    One-time: let insomnia switch without a password
                               (allows only its exact pmset/powermetrics commands).
  insomnia uninstall-nopasswd  Remove that rule again.
  insomnia nopasswd-status     Exit 0 if the rule is installed.
  insomnia heal           Restore normal sleep if it is disabled with no watchdog
                          running (after a crash, kill -9 or reboot mid-session).
  insomnia heal-agent install|uninstall|status
                          A login agent that runs "heal" at login and every minute.

Options for "on":
  --hours N          Stop after N hours (decimals ok). Default: no limit.
  --min-battery P    On battery power, stop and sleep below P%. Default: 20.
  --max-temp C       Stop and sleep if battery temperature exceeds C °C. Default: 45.
  --low-power        Switch to Low Power Mode while running (less heat), restore after.
  --interval S       Watchdog check interval in seconds. Default: 30.
  --fg               Stay in the foreground; Ctrl+C restores normal sleep.
  --remote DIR       Also start Claude Remote Control in DIR, so the Claude phone app
                     (Code tab) or claude.ai/code can open existing sessions and create
                     new ones that run on this Mac. Stops together with insomnia.
  --remote-spawn M   Where phone-created sessions run: same-dir (default) or worktree.

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

remote_pid() {
  [ -f "$REMOTE_PIDFILE" ] || return 1
  local pid
  pid=$(cat "$REMOTE_PIDFILE" 2>/dev/null)
  [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1 && echo "$pid"
}

remote_url() {
  sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$REMOTE_LOG" 2>/dev/null | grep -Eo 'https://claude\.ai/code[^ ]*' | tail -1
}

start_remote() {
  local bin dir pid
  if remote_pid >/dev/null; then
    echo "Remote Control already running (pid $(remote_pid))."
    return 0
  fi
  dir=$(cd "$REMOTE_DIR" 2>/dev/null && pwd) || { echo "No such folder: $REMOTE_DIR" >&2; return 1; }
  if on_battery && [ "$(batt_percent)" -lt "$REMOTE_MIN_BATTERY" ]; then
    echo "Battery is at $(batt_percent)%, below ${REMOTE_MIN_BATTERY}%. Plug in to start phone access." >&2
    return 1
  fi
  bin=$(claude_bin) || { echo "claude CLI not found" >&2; return 1; }
  : > "$REMOTE_LOG"
  local name
  name="$(scutil --get ComputerName 2>/dev/null || hostname) insomnia"
  ( cd "$dir" && trap '' HUP && exec "$bin" remote-control --name "$name" --spawn "$REMOTE_SPAWN" ) </dev/null >"$REMOTE_LOG" 2>&1 &
  echo $! > "$REMOTE_PIDFILE"
  for _ in $(seq 1 30); do
    grep -q "Connected" "$REMOTE_LOG" 2>/dev/null && break
    pid=$(remote_pid) || break
    sleep 1
  done
  if remote_pid >/dev/null && grep -q "Connected" "$REMOTE_LOG"; then
    echo "$dir" > "$REMOTE_DIRFILE"
    mkdir -p "$(dirname "$LAST_DIR_FILE")" && echo "$dir" > "$LAST_DIR_FILE"
    ( trap '' HUP; exec "$0" _remote_guard ) </dev/null >>"$LOG" 2>&1 &
    echo "Remote Control is ON in $dir (new phone sessions: $REMOTE_SPAWN)."
    echo "It stops by itself if the Mac is on battery below ${REMOTE_MIN_BATTERY}%."
    echo "Open the Claude app > Code on your phone, or: $(remote_url)"
  else
    echo "Remote Control failed to start, see $REMOTE_LOG" >&2
    stop_remote
    return 1
  fi
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
}

stop_remote() {
  local pid
  if pid=$(remote_pid); then
    kill_tree "$pid"
  fi
  rm -f "$REMOTE_PIDFILE" "$REMOTE_DIRFILE"
}

cleanup() {
  trap - EXIT INT TERM HUP
  [ -n "$CAFF_PID" ] && kill "$CAFF_PID" 2>/dev/null
  priv /usr/bin/pmset -a disablesleep 0
  [ -n "$ORIG_PM_BATT" ] && priv /usr/bin/pmset -b powermode "$ORIG_PM_BATT"
  [ -n "$ORIG_PM_AC" ] && priv /usr/bin/pmset -c powermode "$ORIG_PM_AC"
  rm -f "$PIDFILE"
  log "normal sleep restored ($STOP_REASON)"
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
      --remote) REMOTE_DIR="$2"; shift 2 ;;
      --remote-spawn) REMOTE_SPAWN="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
  done
}

cmd_on() {
  local orig=("$@") pid
  parse_opts "$@"
  if pid=$(running_pid); then
    echo "Already running (pid $pid). Use 'insomnia off' to stop it." >&2
    exit 1
  fi
  if ! is_root && ! has_rule; then
    sudo -v || exit 1
    if [ -n "$REMOTE_DIR" ]; then start_remote || exit 1; fi
    exec sudo "$0" on ${orig[@]+"${orig[@]}"}
  fi
  if ! is_root && [ -n "$REMOTE_DIR" ]; then
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
      echo "Failed to start, see $LOG" >&2
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

  log "insomnia ON (power=$(power_source), battery=$(batt_percent)%, temp=$(batt_temp)°C, thermal=$(thermal_pressure), limit=${HOURS}h, min-battery=${MIN_BATTERY}%, max-temp=${MAX_BATT_TEMP}°C, low-power=$LOW_POWER)"
  [ -t 1 ] && echo "You can close the lid now. Ctrl+C here, or 'insomnia off' from any terminal, restores normal sleep."

  while :; do
    reason=$(check_limits)
    if [ -n "$reason" ]; then
      STOP_REASON="$reason"; SLEEP_AFTER=1; exit 0
    fi
    now=$(date +%s)
    if [ "$deadline" -gt 0 ] && [ "$now" -ge "$deadline" ]; then
      STOP_REASON="time limit of ${HOURS}h reached"; SLEEP_AFTER=1; exit 0
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

cmd_status() {
  local pid sd
  sd=$(sleep_disabled)
  if pid=$(running_pid); then
    echo "Session:          running (pid $pid)"
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
  if pid=$(remote_pid); then
    echo "Remote Control:   running (pid $pid) $(remote_url)"
  else
    echo "Remote Control:   not running"
  fi
  echo "Log:              $LOG"
}

cmd_state() {
  local pid sd
  sd=$(sleep_disabled)
  if running_pid >/dev/null; then echo "running=1"; else echo "running=0"; fi
  echo "sleep_disabled=${sd:-0}"
  if pid=$(remote_pid); then
    echo "remote=1"
    echo "remote_dir=$(cat "$REMOTE_DIRFILE" 2>/dev/null)"
    echo "remote_url=$(remote_url)"
  else
    echo "remote=0"
  fi
  echo "lid=$(lid_state)"
  echo "power=$(power_source)"
  echo "battery=$(batt_percent)"
  echo "temp=$(batt_temp)"
  if has_rule; then echo "nopasswd=1"; else echo "nopasswd=0"; fi
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
  state) cmd_state ;;
  recent-dirs) cmd_recent_dirs "${2:-8}" ;;
  remote-on)
    REMOTE_DIR="${2:-}"
    [ -n "$REMOTE_DIR" ] || { echo "Usage: insomnia remote-on DIR" >&2; exit 2; }
    shift 2; parse_opts "$@"; start_remote ;;
  remote-off) stop_remote; echo "Remote Control stopped." ;;
  install-nopasswd) cmd_install_nopasswd ;;
  uninstall-nopasswd) sudo rm -f "$SUDOERS_FILE" && echo "Removed $SUDOERS_FILE." ;;
  nopasswd-status) has_rule ;;
  heal) cmd_heal ;;
  heal-agent) cmd_heal_agent "${2:-status}" ;;
  -h|--help|help|"") usage ;;
  *) echo "Unknown command: $1" >&2; usage; exit 2 ;;
esac
