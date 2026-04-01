#!/usr/bin/env bash

set -u

APP_NAME="limit-tc-port"
APP_AUTHOR="Behnam (@b3hnamrjd)"
CONFIG_DIR="/etc/limit-tc-port"
CONFIG_FILE="$CONFIG_DIR/config"
RULES_DB="$CONFIG_DIR/rules.db"
SCHEDULES_DB="$CONFIG_DIR/schedules.db"
LOG_FILE="/var/log/limit-tc-port.log"
SERVICE_FILE="/etc/systemd/system/limit-tc-port.service"
SCHEDULER_SERVICE_FILE="/etc/systemd/system/limit-tc-port-scheduler.service"
SCHEDULER_TIMER_FILE="/etc/systemd/system/limit-tc-port-scheduler.timer"
BIN_PATH="/usr/local/bin/limit-tc-port"
STATE_DIR="/run/limit-tc-port"
SCHEDULE_HASH_FILE="$STATE_DIR/schedule.hash"

INTERFACE=""
IFB_DEV="ifb0"
LINK_CEIL="10000mbit"

RED="\033[1;31m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
MAGENTA="\033[1;35m"
DIM="\033[2m"
RESET="\033[0m"

ts() {
  date "+%Y-%m-%d %H:%M:%S"
}

log_msg() {
  local level="$1"
  local message="$2"
  mkdir -p "$CONFIG_DIR" >/dev/null 2>&1 || true
  touch "$LOG_FILE" >/dev/null 2>&1 || true
  printf "[%s] [%s] %s\n" "$(ts)" "$level" "$message" >>"$LOG_FILE" 2>/dev/null || true
}

print_ok() {
  echo -e "${GREEN}[OK]${RESET} $1"
}

print_warn() {
  echo -e "${YELLOW}[WARN]${RESET} $1"
}

print_err() {
  echo -e "${RED}[ERR]${RESET} $1"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    print_err "Run as root."
    exit 1
  fi
}

require_commands() {
  local missing=()
  local cmd
  for cmd in tc ip ss awk sort uniq paste modprobe cksum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    print_err "Missing dependencies: ${missing[*]}"
    exit 1
  fi
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1
}

detect_default_interface() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

ensure_storage() {
  mkdir -p "$CONFIG_DIR"
  mkdir -p "$STATE_DIR" >/dev/null 2>&1 || true
  touch "$LOG_FILE"
  if [[ ! -f "$RULES_DB" ]]; then
    cat >"$RULES_DB" <<'EOF'
# id|enabled|name|ports|proto|down_kbit|up_kbit|burst_kb|created_at|updated_at
EOF
  fi
  if [[ ! -f "$SCHEDULES_DB" ]]; then
    cat >"$SCHEDULES_DB" <<'EOF'
# sid|rule_id|enabled|label|days|start_hhmm|end_hhmm|down_kbit|up_kbit|burst_kb|priority|created_at|updated_at
EOF
  fi
}

save_config() {
  cat >"$CONFIG_FILE" <<EOF
INTERFACE="${INTERFACE}"
IFB_DEV="${IFB_DEV}"
LINK_CEIL="${LINK_CEIL}"
EOF
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi

  if [[ -z "${INTERFACE:-}" ]]; then
    INTERFACE="$(detect_default_interface || true)"
  fi
  IFB_DEV="${IFB_DEV:-ifb0}"
  LINK_CEIL="${LINK_CEIL:-10000mbit}"
}

is_non_negative_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

to_lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

rules_lines() {
  grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$RULES_DB" || true
}

count_saved_rules() {
  rules_lines | wc -l | awk '{print $1}'
}

count_enabled_rules() {
  rules_lines | awk -F'|' '$2=="1"{c++} END{print c+0}'
}

count_disabled_rules() {
  local total enabled
  total="$(count_saved_rules)"
  enabled="$(count_enabled_rules)"
  echo $((total - enabled))
}

schedules_lines() {
  grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$SCHEDULES_DB" || true
}

count_saved_schedules() {
  schedules_lines | wc -l | awk '{print $1}'
}

count_enabled_schedules() {
  schedules_lines | awk -F'|' '$3=="1"{c++} END{print c+0}'
}

ifb_status() {
  if ! ip link show "$IFB_DEV" >/dev/null 2>&1; then
    echo "MISSING"
    return
  fi
  if ip -o link show "$IFB_DEV" | grep -q "state UP"; then
    echo "UP"
  else
    echo "DOWN"
  fi
}

validate_ports() {
  local raw
  local p
  raw="$(echo "$1" | tr -d '[:space:]')"
  [[ -z "$raw" ]] && return 1
  IFS=',' read -r -a _ports <<<"$raw"
  for p in "${_ports[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ((p >= 1 && p <= 65535)) || return 1
  done
  return 0
}

normalize_ports() {
  echo "$1" \
    | tr -d '[:space:]' \
    | tr ',' '\n' \
    | awk '($0 ~ /^[0-9]+$/ && $0>=1 && $0<=65535){print $0}' \
    | sort -n \
    | uniq \
    | paste -sd, -
}

validate_proto() {
  case "$(to_lower "$1")" in
    tcp|udp|both) return 0 ;;
    *) return 1 ;;
  esac
}

proto_words() {
  case "$1" in
    tcp) echo "tcp" ;;
    udp) echo "udp" ;;
    both) echo "tcp udp" ;;
    *) return 1 ;;
  esac
}

sanitize_label() {
  echo "${1:-}" | tr '|' '/' | tr -d '\r'
}

validate_hhmm() {
  [[ "${1:-}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

hhmm_to_minutes() {
  local hh mm
  hh="${1%%:*}"
  mm="${1##*:}"
  echo $((10#$hh * 60 + 10#$mm))
}

day_name_from_num() {
  case "$1" in
    1) echo "mon" ;;
    2) echo "tue" ;;
    3) echo "wed" ;;
    4) echo "thu" ;;
    5) echo "fri" ;;
    6) echo "sat" ;;
    7) echo "sun" ;;
    *) echo "" ;;
  esac
}

normalize_days() {
  local raw token
  local normalized=""
  local -a _days
  raw="$(to_lower "$(echo "${1:-}" | tr -d '[:space:]')")"
  [[ -z "$raw" ]] && return 1

  case "$raw" in
    all|weekday|weekend)
      echo "$raw"
      return 0
      ;;
  esac

  IFS=',' read -r -a _days <<<"$raw"
  for token in "${_days[@]}"; do
    case "$token" in
      mon|tue|wed|thu|fri|sat|sun)
        if [[ ",$normalized," != *",$token,"* ]]; then
          normalized="${normalized:+$normalized,}$token"
        fi
        ;;
      *)
        return 1
        ;;
    esac
  done

  [[ -n "$normalized" ]] || return 1

  local ordered="" d
  for d in mon tue wed thu fri sat sun; do
    if [[ ",$normalized," == *",$d,"* ]]; then
      ordered="${ordered:+$ordered,}$d"
    fi
  done

  echo "$ordered"
}

schedule_day_matches() {
  local days="$1"
  local now_num now_day
  now_num="$(date +%u)"

  case "$days" in
    all) return 0 ;;
    weekday) (( now_num >= 1 && now_num <= 5 )); return $? ;;
    weekend) (( now_num == 6 || now_num == 7 )); return $? ;;
  esac

  now_day="$(day_name_from_num "$now_num")"
  [[ ",$days," == *",$now_day,"* ]]
}

schedule_time_matches() {
  local start="$1" end="$2" now
  local start_m end_m now_m
  now="$(date +%H:%M)"

  validate_hhmm "$start" || return 1
  validate_hhmm "$end" || return 1
  validate_hhmm "$now" || return 1

  start_m="$(hhmm_to_minutes "$start")"
  end_m="$(hhmm_to_minutes "$end")"
  now_m="$(hhmm_to_minutes "$now")"

  if (( start_m == end_m )); then
    return 0
  fi
  if (( start_m < end_m )); then
    (( now_m >= start_m && now_m < end_m ))
    return $?
  fi

  (( now_m >= start_m || now_m < end_m ))
}

schedule_is_active_now() {
  local days="$1" start="$2" end="$3"
  schedule_day_matches "$days" || return 1
  schedule_time_matches "$start" "$end" || return 1
  return 0
}

next_schedule_id() {
  local max_id
  max_id="$(schedules_lines | awk -F'|' 'BEGIN{m=0} {if($1+0>m)m=$1+0} END{print m+0}')"
  echo $((max_id + 1))
}

get_schedule_by_id() {
  local sid="$1"
  schedules_lines | awk -F'|' -v x="$sid" '$1==x{print; exit}'
}

replace_schedule_line() {
  local sid="$1" new_line="$2" tmp_file
  tmp_file="$(mktemp)"
  awk -F'|' -v x="$sid" -v nl="$new_line" '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next}
  $1==x {print nl; found=1; next}
  {print}
  END {if(found!=1) exit 1}
  ' "$SCHEDULES_DB" >"$tmp_file" && mv "$tmp_file" "$SCHEDULES_DB"
}

delete_schedule_line() {
  local sid="$1" tmp_file
  tmp_file="$(mktemp)"
  awk -F'|' -v x="$sid" '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next}
  $1==x {found=1; next}
  {print}
  END {if(found!=1) exit 1}
  ' "$SCHEDULES_DB" >"$tmp_file" && mv "$tmp_file" "$SCHEDULES_DB"
}

active_schedule_for_rule() {
  local rule_id="$1"
  local best_prio=-2147483647
  local best_sid=0
  local best_line=""
  local sid rid enabled label days start end down up burst priority created updated

  while IFS='|' read -r sid rid enabled label days start end down up burst priority created updated; do
    [[ "$rid" == "$rule_id" ]] || continue
    [[ "$enabled" == "1" ]] || continue
    schedule_is_active_now "$days" "$start" "$end" || continue
    is_non_negative_int "$priority" || priority=100
    is_non_negative_int "$sid" || sid=0

    if (( priority > best_prio || (priority == best_prio && sid > best_sid) )); then
      best_prio="$priority"
      best_sid="$sid"
      best_line="$sid|$rid|$enabled|$label|$days|$start|$end|$down|$up|$burst|$priority|$created|$updated"
    fi
  done < <(schedules_lines)

  [[ -n "$best_line" ]] && echo "$best_line"
}

resolve_effective_limits() {
  local rule_id="$1" base_down="$2" base_up="$3" base_burst="$4"
  local eff_down="$base_down" eff_up="$base_up" eff_burst="$base_burst"
  local sched sid rid enabled label days start end down up burst priority created updated

  sched="$(active_schedule_for_rule "$rule_id")"
  if [[ -n "$sched" ]]; then
    IFS='|' read -r sid rid enabled label days start end down up burst priority created updated <<<"$sched"
    is_non_negative_int "$down" && eff_down="$down"
    is_non_negative_int "$up" && eff_up="$up"
    is_non_negative_int "$burst" && eff_burst="$burst"
    if [[ "$eff_burst" -eq 0 ]]; then
      eff_burst=32
    fi
    echo "$eff_down|$eff_up|$eff_burst|schedule|$sid|$label"
    return
  fi

  if [[ "$eff_burst" -eq 0 ]]; then
    eff_burst=32
  fi
  echo "$eff_down|$eff_up|$eff_burst|rule|-|-"
}

count_active_schedules_now() {
  local c=0
  local sid rid enabled label days start end down up burst priority created updated
  while IFS='|' read -r sid rid enabled label days start end down up burst priority created updated; do
    [[ "$enabled" == "1" ]] || continue
    if schedule_is_active_now "$days" "$start" "$end"; then
      ((c++))
    fi
  done < <(schedules_lines)
  echo "$c"
}

list_schedules() {
  local count
  count="$(count_saved_schedules)"
  if [[ "$count" -eq 0 ]]; then
    echo "No schedule windows."
    return
  fi

  printf "%-4s %-5s %-7s %-14s %-16s %-5s %-5s %-7s %-8s %-18s\n" \
    "SID" "Rule" "State" "When" "Days" "Down" "Up" "Burst" "Prio" "Label"
  printf "%-4s %-5s %-7s %-14s %-16s %-5s %-5s %-7s %-8s %-18s\n" \
    "----" "-----" "-------" "--------------" "----------------" "-----" "-----" "-------" "--------" "------------------"

  local sid rid enabled label days start end down up burst priority created updated status
  while IFS='|' read -r sid rid enabled label days start end down up burst priority created updated; do
    status="OFF"
    [[ "$enabled" == "1" ]] && status="ON"
    printf "%-4s %-5s %-7s %-14s %-16s %-5s %-5s %-7s %-8s %-18s\n" \
      "$sid" "$rid" "$status" "$start-$end" "$days" "$down" "$up" "$burst" "$priority" "$label"
  done < <(schedules_lines)
}

preview_effective_limits_now() {
  local count
  count="$(count_saved_rules)"
  if [[ "$count" -eq 0 ]]; then
    echo "No saved rules."
    return
  fi

  printf "%-4s %-18s %-7s %-8s %-8s %-8s %-10s %-8s %-16s\n" \
    "ID" "Name" "Ports" "BaseD" "BaseU" "EffD" "EffU" "Source" "Schedule"
  printf "%-4s %-18s %-7s %-8s %-8s %-8s %-10s %-8s %-16s\n" \
    "----" "------------------" "-------" "--------" "--------" "--------" "----------" "--------" "----------------"

  local id enabled name ports proto down up burst created updated
  local resolved eff_down eff_up eff_burst source sid label
  while IFS='|' read -r id enabled name ports proto down up burst created updated; do
    [[ "$enabled" == "1" ]] || continue
    resolved="$(resolve_effective_limits "$id" "$down" "$up" "$burst")"
    IFS='|' read -r eff_down eff_up eff_burst source sid label <<<"$resolved"
    printf "%-4s %-18s %-7s %-8s %-8s %-8s %-10s %-8s %-16s\n" \
      "$id" "$name" "$ports" "$down" "$up" "$eff_down" "$eff_up" "$source" "${label:--}"
  done < <(rules_lines)
}

add_schedule() {
  local sid rid enabled label days start end down up burst priority now line
  local rule_line

  list_rules
  echo
  rid="$(prompt_input "Rule ID for this schedule")"
  rule_line="$(get_rule_by_id "$rid")"
  if [[ -z "$rule_line" ]]; then
    print_err "Rule not found."
    return 1
  fi

  sid="$(next_schedule_id)"
  label="$(sanitize_label "$(prompt_input "Schedule label" "window-$sid")")"

  while true; do
    days="$(normalize_days "$(prompt_input "Days (all|weekday|weekend|mon,tue,...)" "all")" || true)"
    [[ -n "$days" ]] && break
    echo "Invalid days format."
  done

  while true; do
    start="$(prompt_input "Start time (HH:MM)" "08:00")"
    if validate_hhmm "$start"; then break; fi
    echo "Invalid time format."
  done
  while true; do
    end="$(prompt_input "End time (HH:MM)" "18:00")"
    if validate_hhmm "$end"; then break; fi
    echo "Invalid time format."
  done

  down="$(prompt_non_negative_int "Scheduled download limit (kbit, 0=off)" "0")"
  up="$(prompt_non_negative_int "Scheduled upload limit (kbit, 0=off)" "0")"
  burst="$(prompt_non_negative_int "Scheduled burst (kb)" "32")"
  [[ "$burst" -eq 0 ]] && burst=32
  priority="$(prompt_non_negative_int "Priority (higher wins)" "100")"

  if prompt_yes_no "Enable this schedule now?" "y"; then
    enabled=1
  else
    enabled=0
  fi

  now="$(ts)"
  line="$sid|$rid|$enabled|$label|$days|$start|$end|$down|$up|$burst|$priority|$now|$now"
  echo "$line" >>"$SCHEDULES_DB"
  print_ok "Schedule $sid created for rule $rid."
  print_warn "Enable scheduler timer in Service menu for automatic time-based switching."
}

edit_schedule() {
  local sid line rid enabled label days start end down up burst priority created updated now
  list_schedules
  echo
  sid="$(prompt_input "Schedule SID to edit")"
  line="$(get_schedule_by_id "$sid")"
  if [[ -z "$line" ]]; then
    print_err "Schedule not found."
    return 1
  fi
  IFS='|' read -r sid rid enabled label days start end down up burst priority created updated <<<"$line"

  label="$(sanitize_label "$(prompt_input "Schedule label" "$label")")"
  while true; do
    days="$(normalize_days "$(prompt_input "Days (all|weekday|weekend|mon,tue,...)" "$days")" || true)"
    [[ -n "$days" ]] && break
    echo "Invalid days format."
  done
  while true; do
    start="$(prompt_input "Start time (HH:MM)" "$start")"
    validate_hhmm "$start" && break
    echo "Invalid time format."
  done
  while true; do
    end="$(prompt_input "End time (HH:MM)" "$end")"
    validate_hhmm "$end" && break
    echo "Invalid time format."
  done

  down="$(prompt_non_negative_int "Scheduled download limit (kbit, 0=off)" "$down")"
  up="$(prompt_non_negative_int "Scheduled upload limit (kbit, 0=off)" "$up")"
  burst="$(prompt_non_negative_int "Scheduled burst (kb)" "$burst")"
  [[ "$burst" -eq 0 ]] && burst=32
  priority="$(prompt_non_negative_int "Priority (higher wins)" "$priority")"

  now="$(ts)"
  replace_schedule_line "$sid" "$sid|$rid|$enabled|$label|$days|$start|$end|$down|$up|$burst|$priority|$created|$now" || {
    print_err "Failed to edit schedule."
    return 1
  }
  print_ok "Schedule $sid updated."
}

set_schedule_enabled() {
  local sid="$1" target="$2" line rid enabled label days start end down up burst priority created updated
  line="$(get_schedule_by_id "$sid")"
  if [[ -z "$line" ]]; then
    print_err "Schedule not found."
    return 1
  fi
  IFS='|' read -r sid rid enabled label days start end down up burst priority created updated <<<"$line"
  replace_schedule_line "$sid" "$sid|$rid|$target|$label|$days|$start|$end|$down|$up|$burst|$priority|$created|$(ts)" || {
    print_err "Failed to update schedule state."
    return 1
  }
  if [[ "$target" == "1" ]]; then
    print_ok "Schedule $sid enabled."
  else
    print_ok "Schedule $sid disabled."
  fi
}

delete_schedule() {
  local sid
  list_schedules
  echo
  sid="$(prompt_input "Schedule SID to delete")"
  if ! prompt_yes_no "Delete schedule $sid ?" "n"; then
    echo "Cancelled."
    return 0
  fi
  delete_schedule_line "$sid" || {
    print_err "Schedule not found."
    return 1
  }
  print_ok "Schedule $sid deleted."
}

detect_inbounds() {
  local ports vpn_detected

  ports="$(detect_ports_from_3xui_db)"
  if [[ -n "$ports" ]]; then
    echo "$ports" | ports_to_inbounds
    return
  fi

  ports="$(detect_ports_from_xray_config)"
  if [[ -n "$ports" ]]; then
    echo "$ports" | ports_to_inbounds
    return
  fi

  vpn_detected="$(detect_inbounds_vpn_processes)"
  if [[ -n "$vpn_detected" ]]; then
    echo "$vpn_detected"
    return
  fi

  detect_inbounds_all
}

ss_lines_to_inbounds() {
  awk '
  {
    proto=$1
    addr=$5
    port=addr
    sub(/^.*:/,"",port)
    if (port ~ /^[0-9]+$/ && port>=1 && port<=65535) {
      if (proto ~ /^tcp/) p="tcp";
      else if (proto ~ /^udp/) p="udp";
      else next;
      if (map[port] == "") map[port] = p;
      else if (map[port] !~ p) map[port] = map[port] "," p;
    }
  }
  END {
    for (port in map) {
      has_tcp = (map[port] ~ /tcp/);
      has_udp = (map[port] ~ /udp/);
      if (has_tcp && has_udp) proto="both";
      else if (has_tcp) proto="tcp";
      else proto="udp";
      print port "|" proto;
    }
  }' | sort -n -t'|' -k1,1
}

detect_inbounds_all() {
  ss -H -lntu 2>/dev/null | ss_lines_to_inbounds
}

discover_3xui_db_paths() {
  cat <<'EOF'
/etc/x-ui/x-ui.db
/etc/3x-ui/x-ui.db
/usr/local/x-ui/x-ui.db
/usr/local/etc/x-ui/x-ui.db
/opt/x-ui/x-ui.db
/var/lib/x-ui/x-ui.db
EOF
}

discover_xray_config_paths() {
  cat <<'EOF'
/usr/local/etc/xray/config.json
/etc/xray/config.json
/usr/local/xray/config.json
/opt/xray/config.json
/etc/3x-ui/xray/config.json
/usr/local/x-ui/bin/config.json
EOF
}

read_enabled_ports_from_3xui_db() {
  local db_path="$1"
  local has_inbounds has_enable
  [[ -f "$db_path" ]] || return 0
  has_command sqlite3 || return 0

  has_inbounds="$(sqlite3 -readonly "$db_path" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='inbounds' LIMIT 1;" 2>/dev/null || true)"
  [[ "$has_inbounds" == "1" ]] || return 0

  has_enable="$(sqlite3 -readonly "$db_path" "SELECT 1 FROM pragma_table_info('inbounds') WHERE name='enable' LIMIT 1;" 2>/dev/null || true)"

  if [[ "$has_enable" == "1" ]]; then
    sqlite3 -readonly "$db_path" "SELECT port FROM inbounds WHERE enable = 1;" 2>/dev/null || true
  else
    sqlite3 -readonly "$db_path" "SELECT port FROM inbounds;" 2>/dev/null || true
  fi
}

detect_ports_from_3xui_db() {
  local path
  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    read_enabled_ports_from_3xui_db "$path"
  done < <(discover_3xui_db_paths) \
    | awk '($0 ~ /^[0-9]+$/ && $0>=1 && $0<=65535){print $0}' \
    | sort -n \
    | uniq
}

read_ports_from_xray_config_jq() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 0
  has_command jq || return 0
  jq -r '.inbounds[]? | .port // empty' "$cfg" 2>/dev/null || true
}

read_ports_from_xray_config_grep() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 0
  grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$cfg" 2>/dev/null \
    | grep -oE '[0-9]+' \
    || true
}

detect_ports_from_xray_config() {
  local path
  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    if has_command jq; then
      read_ports_from_xray_config_jq "$path"
    else
      read_ports_from_xray_config_grep "$path"
    fi
  done < <(discover_xray_config_paths) \
    | awk '($0 ~ /^[0-9]+$/ && $0>=1 && $0<=65535){print $0}' \
    | sort -n \
    | uniq
}

ports_to_inbounds() {
  local ss_map_file
  ss_map_file="$(mktemp)"
  detect_inbounds_all >"$ss_map_file"

  awk -F'|' '
    NR==FNR {
      if ($1 ~ /^[0-9]+$/ && $2 != "") proto[$1]=$2;
      next
    }
    $1 ~ /^[0-9]+$/ {
      p=$1
      pr=(p in proto)?proto[p]:"both"
      print p "|" pr
    }
  ' "$ss_map_file" - | sort -n -t'|' -k1,1 | uniq

  rm -f "$ss_map_file"
}

detect_inbounds_vpn_processes() {
  ss -H -lntup 2>/dev/null \
    | awk 'tolower($0) ~ /(xray|v2ray|sing-box|x-ui|3x-ui)/ {print}' \
    | ss_lines_to_inbounds
}

detected_source_label() {
  if [[ -n "$(detect_ports_from_3xui_db)" ]]; then
    echo "3xui-db"
    return
  fi
  if [[ -n "$(detect_ports_from_xray_config)" ]]; then
    echo "xray-config"
    return
  fi
  if [[ -n "$(detect_inbounds_vpn_processes)" ]]; then
    echo "vpn-processes"
    return
  fi
  if [[ -n "$(detect_inbounds_all)" ]]; then
    echo "all-listeners"
    return
  fi
  echo "none"
}

detected_ports_csv() {
  detect_inbounds | cut -d'|' -f1 | paste -sd, -
}

print_detected_inbounds() {
  local found=0
  echo "Detected inbound ports (source: $(detected_source_label)):"
  while IFS='|' read -r port proto; do
    found=1
    printf "  - %-6s %s\n" "$port" "$proto"
  done < <(detect_inbounds)
  if [[ "$found" -eq 0 ]]; then
    echo "  (none)"
  fi
}

prompt_input() {
  local label="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    echo "${value:-$default}"
  else
    read -r -p "$label: " value
    echo "$value"
  fi
}

prompt_yes_no() {
  local label="$1"
  local default="${2:-y}"
  local answer
  while true; do
    if [[ "$default" == "y" ]]; then
      read -r -p "$label [Y/n]: " answer
      answer="${answer:-y}"
    else
      read -r -p "$label [y/N]: " answer
      answer="${answer:-n}"
    fi
    answer="$(to_lower "$answer")"
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
    echo "Please answer y or n."
  done
}

prompt_non_negative_int() {
  local label="$1"
  local default="${2:-}"
  local val
  while true; do
    val="$(prompt_input "$label" "$default")"
    if is_non_negative_int "$val"; then
      echo "$val"
      return
    fi
    echo "Value must be a non-negative integer."
  done
}

next_rule_id() {
  local max_id
  max_id="$(rules_lines | awk -F'|' 'BEGIN{m=0} {if($1+0>m)m=$1+0} END{print m+0}')"
  echo $((max_id + 1))
}

get_rule_by_id() {
  local id="$1"
  rules_lines | awk -F'|' -v rid="$id" '$1==rid{print; exit}'
}

replace_rule_line() {
  local id="$1"
  local new_line="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  awk -F'|' -v rid="$id" -v nl="$new_line" '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next}
  $1==rid {print nl; found=1; next}
  {print}
  END {if(found!=1) exit 1}
  ' "$RULES_DB" >"$tmp_file" && mv "$tmp_file" "$RULES_DB"
}

delete_rule_line() {
  local id="$1"
  local tmp_file
  tmp_file="$(mktemp)"
  awk -F'|' -v rid="$id" '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next}
  $1==rid {found=1; next}
  {print}
  END {if(found!=1) exit 1}
  ' "$RULES_DB" >"$tmp_file" && mv "$tmp_file" "$RULES_DB"
}

list_rules() {
  local count
  count="$(count_saved_rules)"
  if [[ "$count" -eq 0 ]]; then
    echo "No saved rules."
    return
  fi
  printf "%-4s %-7s %-20s %-18s %-8s %-10s %-10s %-8s\n" "ID" "Status" "Name" "Ports" "Proto" "Down(k)" "Up(k)" "Burst"
  printf "%-4s %-7s %-20s %-18s %-8s %-10s %-10s %-8s\n" "----" "-------" "--------------------" "------------------" "--------" "----------" "----------" "--------"
  while IFS='|' read -r id enabled name ports proto down up burst created updated; do
    local status="OFF"
    [[ "$enabled" == "1" ]] && status="ON"
    printf "%-4s %-7s %-20s %-18s %-8s %-10s %-10s %-8s\n" "$id" "$status" "$name" "$ports" "$proto" "$down" "$up" "$burst"
  done < <(rules_lines)
}

add_rule() {
  local default_ports="${1:-}"
  local default_proto="${2:-both}"
  local id name ports proto down up burst enabled now line

  id="$(next_rule_id)"
  name="$(prompt_input "Rule name" "rule-$id")"

  while true; do
    ports="$(prompt_input "Ports (comma separated)" "$default_ports")"
    if validate_ports "$ports"; then
      ports="$(normalize_ports "$ports")"
      break
    fi
    echo "Invalid port list."
  done

  while true; do
    proto="$(to_lower "$(prompt_input "Protocol (tcp|udp|both)" "$default_proto")")"
    if validate_proto "$proto"; then
      break
    fi
    echo "Invalid protocol."
  done

  down="$(prompt_non_negative_int "Download limit (kbit, 0=disabled)" "0")"
  up="$(prompt_non_negative_int "Upload limit (kbit, 0=disabled)" "0")"

  if [[ "$down" -eq 0 && "$up" -eq 0 ]]; then
    print_err "Both upload and download are 0. Rule not saved."
    return 1
  fi

  burst="$(prompt_non_negative_int "Burst (kb)" "32")"
  if [[ "$burst" -eq 0 ]]; then
    burst=32
  fi

  if prompt_yes_no "Enable this rule now?" "y"; then
    enabled=1
  else
    enabled=0
  fi

  now="$(ts)"
  line="$id|$enabled|$name|$ports|$proto|$down|$up|$burst|$now|$now"
  echo "$line" >>"$RULES_DB"
  log_msg "INFO" "Rule added id=$id ports=$ports proto=$proto down=$down up=$up enabled=$enabled"
  print_ok "Rule $id saved."
}

edit_rule() {
  local id line enabled name ports proto down up burst created updated now
  list_rules
  echo
  id="$(prompt_input "Rule ID to edit")"
  line="$(get_rule_by_id "$id")"
  if [[ -z "$line" ]]; then
    print_err "Rule not found."
    return 1
  fi

  IFS='|' read -r id enabled name ports proto down up burst created updated <<<"$line"

  name="$(prompt_input "Rule name" "$name")"

  while true; do
    ports="$(prompt_input "Ports (comma separated)" "$ports")"
    if validate_ports "$ports"; then
      ports="$(normalize_ports "$ports")"
      break
    fi
    echo "Invalid port list."
  done

  while true; do
    proto="$(to_lower "$(prompt_input "Protocol (tcp|udp|both)" "$proto")")"
    if validate_proto "$proto"; then
      break
    fi
    echo "Invalid protocol."
  done

  down="$(prompt_non_negative_int "Download limit (kbit, 0=disabled)" "$down")"
  up="$(prompt_non_negative_int "Upload limit (kbit, 0=disabled)" "$up")"
  if [[ "$down" -eq 0 && "$up" -eq 0 ]]; then
    print_err "Both upload and download are 0. Update cancelled."
    return 1
  fi

  burst="$(prompt_non_negative_int "Burst (kb)" "$burst")"
  if [[ "$burst" -eq 0 ]]; then
    burst=32
  fi

  now="$(ts)"
  replace_rule_line "$id" "$id|$enabled|$name|$ports|$proto|$down|$up|$burst|$created|$now" || {
    print_err "Failed to update rule."
    return 1
  }

  log_msg "INFO" "Rule edited id=$id"
  print_ok "Rule $id updated."
}

set_rule_enabled() {
  local id="$1"
  local target="$2"
  local line enabled name ports proto down up burst created updated
  line="$(get_rule_by_id "$id")"
  if [[ -z "$line" ]]; then
    print_err "Rule not found."
    return 1
  fi
  IFS='|' read -r id enabled name ports proto down up burst created updated <<<"$line"
  replace_rule_line "$id" "$id|$target|$name|$ports|$proto|$down|$up|$burst|$created|$(ts)" || {
    print_err "Failed to update status."
    return 1
  }
  if [[ "$target" == "1" ]]; then
    print_ok "Rule $id enabled."
  else
    print_ok "Rule $id disabled."
  fi
}

delete_rule() {
  local id
  list_rules
  echo
  id="$(prompt_input "Rule ID to delete")"
  if ! prompt_yes_no "Delete rule $id ?" "n"; then
    echo "Cancelled."
    return 0
  fi
  delete_rule_line "$id" || {
    print_err "Rule not found."
    return 1
  }
  log_msg "INFO" "Rule deleted id=$id"
  print_ok "Rule $id deleted."
}

setup_ifb() {
  modprobe ifb numifbs=1 >/dev/null 2>&1 || modprobe ifb >/dev/null 2>&1 || true
  if ! ip link show "$IFB_DEV" >/dev/null 2>&1; then
    ip link add "$IFB_DEV" type ifb >/dev/null 2>&1 || true
  fi
  ip link set dev "$IFB_DEV" up >/dev/null 2>&1 || {
    print_err "Could not bring up $IFB_DEV."
    return 1
  }
  return 0
}

clear_tc() {
  tc qdisc del dev "$INTERFACE" root >/dev/null 2>&1 || true
  tc qdisc del dev "$INTERFACE" ingress >/dev/null 2>&1 || true
  tc qdisc del dev "$IFB_DEV" root >/dev/null 2>&1 || true
  rm -f "$SCHEDULE_HASH_FILE" >/dev/null 2>&1 || true
}

add_port_filter() {
  local dev="$1"
  local parent="$2"
  local classid="$3"
  local proto="$4"
  local field="$5"
  local port="$6"
  local prio="$7"
  local proto_num

  case "$proto" in
    tcp) proto_num=6 ;;
    udp) proto_num=17 ;;
    *) return 1 ;;
  esac

  tc filter add dev "$dev" protocol ip parent "$parent" prio "$prio" u32 \
    match ip protocol "$proto_num" 0xff \
    match ip "$field" "$port" 0xffff \
    flowid "$classid" >/dev/null 2>&1
}

build_effective_signature() {
  {
    echo "interface=${INTERFACE}"
    echo "ifb=${IFB_DEV}"
    echo "link_ceil=${LINK_CEIL}"
    local id enabled name ports proto down up burst created updated resolved eff_down eff_up eff_burst source sid label
    while IFS='|' read -r id enabled name ports proto down up burst created updated; do
      [[ "$enabled" == "1" ]] || continue
      ports="$(normalize_ports "$ports")"
      [[ -n "$ports" ]] || continue
      if ! validate_proto "$proto"; then
        continue
      fi
      if ! is_non_negative_int "$down"; then down=0; fi
      if ! is_non_negative_int "$up"; then up=0; fi
      if ! is_non_negative_int "$burst"; then burst=32; fi
      if [[ "$burst" -eq 0 ]]; then burst=32; fi
      resolved="$(resolve_effective_limits "$id" "$down" "$up" "$burst")"
      IFS='|' read -r eff_down eff_up eff_burst source sid label <<<"$resolved"
      echo "rule=${id}|ports=${ports}|proto=${proto}|down=${eff_down}|up=${eff_up}|burst=${eff_burst}|src=${source}|sid=${sid}"
    done < <(rules_lines)
  } | sort
}

effective_signature_hash() {
  build_effective_signature | cksum | awk '{print $1 ":" $2}'
}

save_effective_signature_hash() {
  mkdir -p "$STATE_DIR" >/dev/null 2>&1 || true
  effective_signature_hash >"$SCHEDULE_HASH_FILE"
}

tick_apply_if_needed() {
  local current_hash previous_hash
  current_hash="$(effective_signature_hash)"
  if [[ -f "$SCHEDULE_HASH_FILE" ]]; then
    previous_hash="$(cat "$SCHEDULE_HASH_FILE" 2>/dev/null || true)"
  else
    previous_hash=""
  fi

  if [[ -n "$previous_hash" && "$previous_hash" == "$current_hash" ]]; then
    echo "[INFO] No schedule change detected. Skip re-apply."
    return 0
  fi

  apply_enabled_rules || return 1
  save_effective_signature_hash
  echo "[INFO] Schedule change detected. tc rules refreshed."
}

apply_enabled_rules() {
  local cid_up=100
  local cid_down=100
  local prio_up=100
  local prio_down=100
  local line_count=0

  if [[ -z "$INTERFACE" ]]; then
    print_err "No interface selected."
    return 1
  fi
  if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    print_err "Interface $INTERFACE not found."
    return 1
  fi

  setup_ifb || return 1
  clear_tc

  tc qdisc replace dev "$INTERFACE" root handle 1: htb default 10 || return 1
  tc class replace dev "$INTERFACE" parent 1: classid 1:1 htb rate "$LINK_CEIL" ceil "$LINK_CEIL" || return 1
  tc class replace dev "$INTERFACE" parent 1:1 classid 1:10 htb rate "$LINK_CEIL" ceil "$LINK_CEIL" || return 1

  tc qdisc replace dev "$INTERFACE" handle ffff: ingress || return 1
  tc filter replace dev "$INTERFACE" parent ffff: protocol ip u32 match u32 0 0 \
    action mirred egress redirect dev "$IFB_DEV" || return 1

  tc qdisc replace dev "$IFB_DEV" root handle 2: htb default 10 || return 1
  tc class replace dev "$IFB_DEV" parent 2: classid 2:1 htb rate "$LINK_CEIL" ceil "$LINK_CEIL" || return 1
  tc class replace dev "$IFB_DEV" parent 2:1 classid 2:10 htb rate "$LINK_CEIL" ceil "$LINK_CEIL" || return 1

  while IFS='|' read -r id enabled name ports proto down up burst created updated; do
    local proto_list class_up class_down p port resolved source sched_id sched_label

    [[ "$enabled" == "1" ]] || continue
    ((line_count++))

    ports="$(normalize_ports "$ports")"
    [[ -n "$ports" ]] || continue

    if ! validate_proto "$proto"; then
      print_warn "Skipping invalid proto on rule id=$id"
      continue
    fi
    proto_list="$(proto_words "$proto")"

    if ! is_non_negative_int "$down"; then down=0; fi
    if ! is_non_negative_int "$up"; then up=0; fi
    if ! is_non_negative_int "$burst"; then burst=32; fi
    if [[ "$burst" -eq 0 ]]; then burst=32; fi

    resolved="$(resolve_effective_limits "$id" "$down" "$up" "$burst")"
    IFS='|' read -r down up burst source sched_id sched_label <<<"$resolved"

    if [[ "$up" -gt 0 ]]; then
      class_up="1:$cid_up"
      tc class replace dev "$INTERFACE" parent 1:1 classid "$class_up" htb \
        rate "${up}kbit" ceil "${up}kbit" burst "${burst}kb" || continue
      for port in ${ports//,/ }; do
        for p in $proto_list; do
          add_port_filter "$INTERFACE" "1:" "$class_up" "$p" "sport" "$port" "$prio_up" || true
          ((prio_up++))
        done
      done
      ((cid_up++))
    fi

    if [[ "$down" -gt 0 ]]; then
      class_down="2:$cid_down"
      tc class replace dev "$IFB_DEV" parent 2:1 classid "$class_down" htb \
        rate "${down}kbit" ceil "${down}kbit" burst "${burst}kb" || continue
      for port in ${ports//,/ }; do
        for p in $proto_list; do
          add_port_filter "$IFB_DEV" "2:" "$class_down" "$p" "dport" "$port" "$prio_down" || true
          ((prio_down++))
        done
      done
      ((cid_down++))
    fi
  done < <(rules_lines)

  print_ok "Applied enabled rules on $INTERFACE (ifb: $IFB_DEV)."
  log_msg "INFO" "Applied tc rules enabled_count=$(count_enabled_rules)"
  save_effective_signature_hash

  if [[ "$line_count" -eq 0 ]]; then
    print_warn "No enabled rules found. Base tc structure is active."
  fi
}

show_tc_status() {
  echo "Upload classes on $INTERFACE"
  tc -s class show dev "$INTERFACE" 2>/dev/null || true
  echo
  echo "Download classes on $IFB_DEV"
  tc -s class show dev "$IFB_DEV" 2>/dev/null || true
}

generate_debug_report() {
  local report_file
  report_file="/tmp/limit-tc-port-debug-$(date +%Y%m%d-%H%M%S).log"

  {
    echo "=== limit-tc-port debug report ==="
    echo "time: $(ts)"
    echo
    echo "=== config ==="
    echo "interface: ${INTERFACE:-N/A}"
    echo "default-interface: $(detect_default_interface || echo N/A)"
    echo "ifb: ${IFB_DEV}"
    echo "ifb-status: $(ifb_status)"
    echo "link-ceil: ${LINK_CEIL}"
    echo "schedules: saved=$(count_saved_schedules) enabled=$(count_enabled_schedules) active_now=$(count_active_schedules_now)"
    echo
    echo "=== detected inbounds ($(detected_source_label)) ==="
    detect_inbounds || true
    echo
    echo "=== rules db ==="
    cat "$RULES_DB" 2>/dev/null || true
    echo
    echo "=== schedules db ==="
    cat "$SCHEDULES_DB" 2>/dev/null || true
    echo
    echo "=== tc qdisc (main) ==="
    tc qdisc show dev "$INTERFACE" 2>/dev/null || true
    echo
    echo "=== tc class (main) ==="
    tc -s class show dev "$INTERFACE" 2>/dev/null || true
    echo
    echo "=== tc filter (main root 1:) ==="
    tc filter show dev "$INTERFACE" parent 1: 2>/dev/null || true
    echo
    echo "=== tc qdisc (ifb) ==="
    tc qdisc show dev "$IFB_DEV" 2>/dev/null || true
    echo
    echo "=== tc class (ifb) ==="
    tc -s class show dev "$IFB_DEV" 2>/dev/null || true
    echo
    echo "=== tc filter (ifb root 2:) ==="
    tc filter show dev "$IFB_DEV" parent 2: 2>/dev/null || true
    echo
    echo "=== listening sockets ==="
    ss -lntup 2>/dev/null || true
    echo
    if has_systemd; then
      echo "=== service status ==="
      systemctl status --no-pager limit-tc-port.service 2>/dev/null || true
      echo
    fi
    echo "=== end of report ==="
  } >"$report_file"

  print_ok "Debug report created: $report_file"
}

monitor_tc_live() {
  if command -v watch >/dev/null 2>&1; then
    watch -n 1 "echo 'Upload classes on $INTERFACE'; tc -s class show dev $INTERFACE 2>/dev/null; echo; echo 'Download classes on $IFB_DEV'; tc -s class show dev $IFB_DEV 2>/dev/null"
    return
  fi

  echo "Press Ctrl+C to return."
  while true; do
    clear
    echo "=== tc monitor $(ts) ==="
    show_tc_status
    sleep 2
  done
}

backup_rules() {
  local backup_dir backup_file
  backup_dir="$CONFIG_DIR/backups"
  mkdir -p "$backup_dir"
  backup_file="$backup_dir/rules-$(date +%Y%m%d-%H%M%S).db"
  cp "$RULES_DB" "$backup_file"
  print_ok "Backup created: $backup_file"
}

restore_rules() {
  local path
  path="$(prompt_input "Backup file path")"
  if [[ ! -f "$path" ]]; then
    print_err "File not found."
    return 1
  fi
  cp "$path" "$RULES_DB"
  print_ok "Rules restored."
}

pick_interface() {
  local ifaces=()
  local idx choice
  while IFS= read -r line; do
    ifaces+=("$line")
  done < <(ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^lo$')

  if (( ${#ifaces[@]} == 0 )); then
    print_err "No interfaces found."
    return 1
  fi

  echo "Available interfaces:"
  for idx in "${!ifaces[@]}"; do
    printf "  [%d] %s\n" "$((idx + 1))" "${ifaces[$idx]}"
  done

  while true; do
    choice="$(prompt_input "Select interface number")"
    if is_non_negative_int "$choice" && ((choice >= 1 && choice <= ${#ifaces[@]})); then
      INTERFACE="${ifaces[$((choice - 1))]}"
      save_config
      print_ok "Interface set to $INTERFACE"
      return 0
    fi
    echo "Invalid selection."
  done
}

quick_wizard() {
  local detected ports proto down up burst name id enabled now
  detected="$(detected_ports_csv)"
  if [[ -z "$detected" ]]; then
    print_warn "No listening ports detected."
    return 1
  fi

  echo "Detected ports: $detected"
  while true; do
    ports="$(prompt_input "Ports for this rule (comma separated)" "$detected")"
    if validate_ports "$ports"; then
      ports="$(normalize_ports "$ports")"
      break
    fi
    echo "Invalid port list."
  done

  while true; do
    proto="$(to_lower "$(prompt_input "Protocol (tcp|udp|both)" "both")")"
    if validate_proto "$proto"; then
      break
    fi
    echo "Invalid protocol."
  done

  down="$(prompt_non_negative_int "Download limit (kbit)" "10240")"
  up="$(prompt_non_negative_int "Upload limit (kbit)" "10240")"
  if [[ "$down" -eq 0 && "$up" -eq 0 ]]; then
    print_err "Both limits cannot be 0."
    return 1
  fi
  burst="$(prompt_non_negative_int "Burst (kb)" "32")"
  [[ "$burst" -eq 0 ]] && burst=32

  id="$(next_rule_id)"
  name="$(prompt_input "Rule name" "wizard-$id")"
  enabled=1
  now="$(ts)"
  echo "$id|$enabled|$name|$ports|$proto|$down|$up|$burst|$now|$now" >>"$RULES_DB"
  print_ok "Wizard rule created and enabled (id=$id)."

  if prompt_yes_no "Apply rules now?" "y"; then
    apply_enabled_rules
  fi
}

install_or_update_service() {
  local self_path
  if ! has_systemd; then
    print_err "systemctl not found. Service install is unavailable on this host."
    return 1
  fi
  self_path="$(readlink -f "$0")"
  if [[ "$self_path" != "$BIN_PATH" ]]; then
    install -m 0755 "$self_path" "$BIN_PATH"
  fi

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Port bandwidth limiter using tc/ifb
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN_PATH} --apply
ExecStop=${BIN_PATH} --clear
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat >"$SCHEDULER_SERVICE_FILE" <<EOF
[Unit]
Description=Time-based scheduler tick for port bandwidth limiter
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN_PATH} --tick
EOF

  cat >"$SCHEDULER_TIMER_FILE" <<EOF
[Unit]
Description=Run limit-tc-port scheduler tick every minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=1s
Persistent=true
Unit=limit-tc-port-scheduler.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  print_ok "Service installed/updated: $SERVICE_FILE"
  print_ok "Scheduler service: $SCHEDULER_SERVICE_FILE"
  print_ok "Scheduler timer: $SCHEDULER_TIMER_FILE"
  print_ok "Script installed: $BIN_PATH"
}

pause_enter() {
  echo
  read -r -p "Press Enter to continue..." _
}

menu_header() {
  local title="$1"
  local bar="======================================================================"
  clear
  echo -e "${BLUE}${bar}${RESET}"
  printf "%s\n" " ${MAGENTA}${title}${RESET}"
  echo -e "${BLUE}${bar}${RESET}"
}

badge_state() {
  case "$1" in
    UP|ON|enabled) echo -e "${GREEN}$1${RESET}" ;;
    DOWN|OFF|disabled|MISSING) echo -e "${RED}$1${RESET}" ;;
    *) echo -e "${YELLOW}$1${RESET}" ;;
  esac
}

service_menu() {
  local choice tick_cmd
  if ! has_systemd; then
    print_err "systemctl not found. Service menu is unavailable."
    pause_enter
    return 1
  fi
  tick_cmd="$BIN_PATH"
  if [[ ! -x "$tick_cmd" ]]; then
    tick_cmd="$(readlink -f "$0")"
  fi
  while true; do
    menu_header "Service Operations"
    echo "[1] Install/Update service files"
    echo "[2] Enable + Start service"
    echo "[3] Restart service"
    echo "[4] Disable + Stop service"
    echo "[5] Show service status"
    echo "[6] Enable scheduler timer"
    echo "[7] Disable scheduler timer"
    echo "[8] Scheduler timer status"
    echo "[9] Run scheduler tick now"
    echo "[0] Back"
    choice="$(prompt_input "Choice")"
    case "$choice" in
      1) install_or_update_service; pause_enter ;;
      2) systemctl enable --now limit-tc-port.service && print_ok "Service enabled and started."; pause_enter ;;
      3) systemctl restart limit-tc-port.service && print_ok "Service restarted."; pause_enter ;;
      4) systemctl disable --now limit-tc-port.service && print_ok "Service stopped and disabled."; pause_enter ;;
      5) systemctl status --no-pager limit-tc-port.service || true; pause_enter ;;
      6) systemctl enable --now limit-tc-port-scheduler.timer && print_ok "Scheduler timer enabled."; pause_enter ;;
      7) systemctl disable --now limit-tc-port-scheduler.timer && print_ok "Scheduler timer disabled."; pause_enter ;;
      8) systemctl status --no-pager limit-tc-port-scheduler.timer || true; pause_enter ;;
      9) "$tick_cmd" --tick; pause_enter ;;
      0) return ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

maintenance_menu() {
  local choice value
  while true; do
    menu_header "Maintenance Toolkit"
    echo "[1] Apply enabled rules now"
    echo "[2] Clear all tc rules"
    echo "[3] Backup rules"
    echo "[4] Restore rules from backup"
    echo "[5] Change interface"
    echo "[6] Set IFB device"
    echo "[7] Set link ceiling"
    echo "[8] Generate debug report"
    echo "[0] Back"
    choice="$(prompt_input "Choice")"
    case "$choice" in
      1) apply_enabled_rules; pause_enter ;;
      2) clear_tc; print_ok "tc rules cleared."; pause_enter ;;
      3) backup_rules; pause_enter ;;
      4) restore_rules; pause_enter ;;
      5) pick_interface; pause_enter ;;
      6)
        value="$(prompt_input "IFB device name" "$IFB_DEV")"
        IFB_DEV="$value"
        save_config
        print_ok "IFB device set to $IFB_DEV"
        pause_enter
        ;;
      7)
        value="$(prompt_input "Link ceiling (example: 1000mbit)" "$LINK_CEIL")"
        LINK_CEIL="$value"
        save_config
        print_ok "Link ceiling set to $LINK_CEIL"
        pause_enter
        ;;
      8)
        generate_debug_report
        pause_enter
        ;;
      0) return ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

rules_menu() {
  local choice id
  while true; do
    menu_header "Rules Studio"
    echo "[1] List rules"
    echo "[2] Add rule"
    echo "[3] Edit rule"
    echo "[4] Enable rule"
    echo "[5] Disable rule"
    echo "[6] Delete rule"
    echo "[7] Apply enabled rules"
    echo "[8] Quick wizard"
    echo "[0] Back"
    choice="$(prompt_input "Choice")"
    case "$choice" in
      1) list_rules; pause_enter ;;
      2) add_rule; pause_enter ;;
      3) edit_rule; pause_enter ;;
      4)
        list_rules
        id="$(prompt_input "Rule ID to enable")"
        set_rule_enabled "$id" "1"
        pause_enter
        ;;
      5)
        list_rules
        id="$(prompt_input "Rule ID to disable")"
        set_rule_enabled "$id" "0"
        pause_enter
        ;;
      6) delete_rule; pause_enter ;;
      7) apply_enabled_rules; pause_enter ;;
      8) quick_wizard; pause_enter ;;
      0) return ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

detected_menu() {
  local choice
  while true; do
    menu_header "Inbound Discovery"
    print_detected_inbounds
    echo
    echo "[1] Create rule from detected ports"
    echo "[0] Back"
    choice="$(prompt_input "Choice")"
    case "$choice" in
      1)
        local default_ports
        default_ports="$(detected_ports_csv)"
        if [[ -z "$default_ports" ]]; then
          print_warn "No detected ports."
          pause_enter
          continue
        fi
        add_rule "$default_ports" "both"
        pause_enter
        ;;
      0) return ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

schedules_menu() {
  local choice sid
  while true; do
    menu_header "Time Schedules"
    echo "Saved schedules : $(count_saved_schedules)"
    echo "Enabled         : $(count_enabled_schedules)"
    echo "Active now      : $(count_active_schedules_now)"
    echo
    echo "[1] List schedules"
    echo "[2] Add schedule window"
    echo "[3] Edit schedule window"
    echo "[4] Enable schedule"
    echo "[5] Disable schedule"
    echo "[6] Delete schedule"
    echo "[7] Preview effective limits now"
    echo "[8] Apply tick now"
    echo "[0] Back"
    choice="$(prompt_input "Choice")"
    case "$choice" in
      1) list_schedules; pause_enter ;;
      2) add_schedule; pause_enter ;;
      3) edit_schedule; pause_enter ;;
      4)
        list_schedules
        sid="$(prompt_input "Schedule SID to enable")"
        set_schedule_enabled "$sid" "1"
        pause_enter
        ;;
      5)
        list_schedules
        sid="$(prompt_input "Schedule SID to disable")"
        set_schedule_enabled "$sid" "0"
        pause_enter
        ;;
      6) delete_schedule; pause_enter ;;
      7) preview_effective_limits_now; pause_enter ;;
      8) tick_apply_if_needed; pause_enter ;;
      0) return ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

render_dashboard() {
  local selected_interface default_interface saved enabled disabled schedules schedules_active detected detected_source ifb_state host_name up_text
  selected_interface="${INTERFACE:-N/A}"
  default_interface="$(detect_default_interface || true)"
  saved="$(count_saved_rules)"
  enabled="$(count_enabled_rules)"
  disabled="$(count_disabled_rules)"
  schedules="$(count_saved_schedules)"
  schedules_active="$(count_active_schedules_now)"
  detected="$(detected_ports_csv)"
  detected_source="$(detected_source_label)"
  detected="${detected:-none}"
  ifb_state="$(ifb_status)"
  host_name="$(hostname 2>/dev/null || echo "server")"
  up_text="$(uptime -p 2>/dev/null || echo "uptime n/a")"
  if [[ "${#detected}" -gt 66 ]]; then
    detected="${detected:0:63}..."
  fi

  echo -e "${BLUE}======================================================================${RESET}"
  echo -e " ${MAGENTA}BWLimiter Control Center${RESET}   ${DIM}host:${host_name}${RESET}"
  echo -e " ${YELLOW}Developed by: ${APP_AUTHOR}${RESET}"
  echo -e "${BLUE}======================================================================${RESET}"
  echo -e " ${CYAN}Network Snapshot${RESET}"
  printf "   Interface      : %s\n" "$selected_interface"
  printf "   Default Route  : %s\n" "${default_interface:-N/A}"
  printf "   IFB Device     : %s\n" "$IFB_DEV"
  printf "   IFB Status     : %b\n" "$(badge_state "$ifb_state")"
  echo
  echo -e " ${CYAN}Policy Snapshot${RESET}"
  printf "   Saved Rules    : %s\n" "$saved"
  printf "   Enabled Rules  : %b\n" "$(badge_state "enabled") ($enabled)"
  printf "   Disabled Rules : %b\n" "$(badge_state "disabled") ($disabled)"
  printf "   Schedules      : %s (active now: %s)\n" "$schedules" "$schedules_active"
  printf "   Detected Ports : %s\n" "$detected"
  printf "   Detected Source: %s\n" "$detected_source"
  echo
  echo -e " ${CYAN}Runtime${RESET}"
  printf "   Uptime         : %s\n" "$up_text"
  printf "   Rules DB       : %s\n" "$RULES_DB"
  printf "   Log File       : %s\n" "$LOG_FILE"
  echo -e "${BLUE}----------------------------------------------------------------------${RESET}"
  echo " [1] Rules Studio   [2] Inbound Discovery   [3] Service Ops"
  echo " [4] Live Monitor   [5] Maintenance Toolkit [6] Quick Wizard"
  echo " [7] Apply Active   [8] Time Schedules      [0] Quit"
}

show_help() {
  cat <<EOF
$APP_NAME - Port bandwidth manager using tc/ifb
Developed by: $APP_AUTHOR

Usage:
  $APP_NAME                  # interactive menu
  $APP_NAME --apply          # apply enabled rules
  $APP_NAME --tick           # apply only if schedule state changed
  $APP_NAME --clear          # clear tc rules
  $APP_NAME --status         # show tc status
  $APP_NAME --list           # list saved rules
  $APP_NAME --list-schedules # list saved schedule windows
  $APP_NAME --install-service
  $APP_NAME --debug-report   # generate debug report in /tmp
  $APP_NAME --help
EOF
}

main_menu() {
  local choice
  while true; do
    clear
    render_dashboard
    echo
    choice="$(prompt_input "Choice")"
    case "$choice" in
      1) rules_menu ;;
      2) detected_menu ;;
      3) service_menu ;;
      4) monitor_tc_live ;;
      5) maintenance_menu ;;
      6) quick_wizard; pause_enter ;;
      7) apply_enabled_rules; pause_enter ;;
      8) schedules_menu ;;
      0) exit 0 ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

main() {
  case "${1:-}" in
    --help|-h)
      show_help
      exit 0
      ;;
  esac

  ensure_storage
  load_config

  case "${1:-}" in
    --apply)
      require_root
      require_commands
      apply_enabled_rules
      exit $?
      ;;
    --tick)
      require_root
      require_commands
      tick_apply_if_needed
      exit $?
      ;;
    --clear)
      require_root
      require_commands
      clear_tc
      print_ok "tc rules cleared."
      exit 0
      ;;
    --status)
      require_root
      show_tc_status
      exit 0
      ;;
    --list)
      list_rules
      exit 0
      ;;
    --list-schedules)
      list_schedules
      exit 0
      ;;
    --install-service)
      require_root
      require_commands
      install_or_update_service
      exit 0
      ;;
    --debug-report)
      require_root
      require_commands
      generate_debug_report
      exit 0
      ;;
    "")
      require_root
      require_commands
      if [[ ! -t 0 ]]; then
        if [[ -r /dev/tty ]]; then
          exec </dev/tty >/dev/tty 2>/dev/tty "$0"
        fi
        print_err "Interactive mode requires a TTY."
        exit 1
      fi
      if [[ -z "$INTERFACE" ]]; then
        print_warn "No default interface found. Please select interface."
        pick_interface
      fi
      save_config
      main_menu
      ;;
    *)
      print_err "Unknown argument: $1"
      show_help
      exit 1
      ;;
  esac
}

main "$@"
