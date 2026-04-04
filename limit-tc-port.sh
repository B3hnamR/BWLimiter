#!/usr/bin/env bash

set -u

APP_NAME="limit-tc-port"
APP_AUTHOR="Behnam (@b3hnamrjd)"
CONFIG_DIR="/etc/limit-tc-port"
CONFIG_FILE="$CONFIG_DIR/config"
RULES_DB="$CONFIG_DIR/rules.db"
SCHEDULES_DB="$CONFIG_DIR/schedules.db"
IPRULES_DB="$CONFIG_DIR/iprules.db"
SNAPSHOTS_DIR="$CONFIG_DIR/snapshots"
LOG_FILE="/var/log/limit-tc-port.log"
SERVICE_FILE="/etc/systemd/system/limit-tc-port.service"
SCHEDULER_SERVICE_FILE="/etc/systemd/system/limit-tc-port-scheduler.service"
SCHEDULER_TIMER_FILE="/etc/systemd/system/limit-tc-port-scheduler.timer"
BIN_PATH="/usr/local/bin/limit-tc-port"
STATE_DIR="/run/limit-tc-port"
SCHEDULE_HASH_FILE="$STATE_DIR/schedule.hash"
NFT_TABLE_FAMILY="inet"
NFT_TABLE_NAME="limit_tc_port"

INTERFACE=""
IFB_DEV="ifb0"
LINK_CEIL="10000mbit"
PROTECTED_PORTS="22"
MIN_PROTECTED_KBIT="128"

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
  mkdir -p "$SNAPSHOTS_DIR"
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
  if [[ ! -f "$IPRULES_DB" ]]; then
    cat >"$IPRULES_DB" <<'EOF'
# iid|enabled|name|cidrs|ports|proto|down_kbit|up_kbit|burst_kb|created_at|updated_at
EOF
  fi
}

save_config() {
  cat >"$CONFIG_FILE" <<EOF
INTERFACE="${INTERFACE}"
IFB_DEV="${IFB_DEV}"
LINK_CEIL="${LINK_CEIL}"
PROTECTED_PORTS="${PROTECTED_PORTS}"
MIN_PROTECTED_KBIT="${MIN_PROTECTED_KBIT}"
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
  PROTECTED_PORTS="${PROTECTED_PORTS:-22}"
  MIN_PROTECTED_KBIT="${MIN_PROTECTED_KBIT:-128}"
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

ip_rules_lines() {
  grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$IPRULES_DB" || true
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

count_saved_ip_rules() {
  ip_rules_lines | wc -l | awk '{print $1}'
}

count_enabled_ip_rules() {
  ip_rules_lines | awk -F'|' '$2=="1"{c++} END{print c+0}'
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

count_snapshots() {
  find "$SNAPSHOTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | awk '{print $1}'
}

is_port_protected() {
  local port="$1"
  local list
  list="$(echo "${PROTECTED_PORTS:-}" | tr -d '[:space:]')"
  [[ -z "$list" ]] && return 1
  [[ ",$list," == *",$port,"* ]]
}

detect_rule_port_proto_overlaps() {
  rules_lines | awk -F'|' '
  $2=="1" {
    split($4, arr, ",");
    for (i in arr) {
      p=arr[i];
      if (p !~ /^[0-9]+$/) continue;
      if ($5=="both") {
        print p "|tcp|" $1;
        print p "|udp|" $1;
      } else if ($5=="tcp" || $5=="udp") {
        print p "|" $5 "|" $1;
      }
    }
  }' \
  | sort -t'|' -k1,1n -k2,2 \
  | awk -F'|' '
  {
    k=$1 "|" $2;
    c[k]++;
    if (ids[k]=="") ids[k]=$3;
    else ids[k]=ids[k] "," $3;
  }
  END {
    for (k in c) {
      if (c[k] > 1) print k "|" ids[k];
    }
  }'
}

detect_ip_rule_exact_overlaps() {
  local iid enabled name cidrs ports proto down up burst created updated
  while IFS='|' read -r iid enabled name cidrs ports proto down up burst created updated; do
    [[ "$enabled" == "1" ]] || continue
    cidrs="$(normalize_ipv4_cidrs "$cidrs")"
    ports="$(normalize_ports_or_any "$ports")"
    proto="$(to_lower "$proto")"
    [[ -n "$cidrs" ]] || continue
    [[ -n "$ports" ]] || ports="any"
    echo "$cidrs|$ports|$proto|$iid"
  done < <(ip_rules_lines) | awk -F'|' '
  {
    k=$1 "|" $2 "|" $3;
    c[k]++;
    if (ids[k]=="") ids[k]=$4;
    else ids[k]=ids[k] "," $4;
  }
  END {
    for (k in c) if (c[k] > 1) print k "|" ids[k];
  }'
}

detect_schedule_same_priority_groups() {
  schedules_lines | awk -F'|' '
  $3=="1" {
    k=$2 "|" $11;
    c[k]++;
    if (ids[k]=="") ids[k]=$1;
    else ids[k]=ids[k] "," $1;
  }
  END {
    for (k in c) if (c[k] > 1) print k "|" ids[k];
  }'
}

run_conflict_guard() {
  local failed=0
  local min_kbit
  local overlaps ip_overlaps same_prio

  min_kbit="${MIN_PROTECTED_KBIT:-128}"
  if ! is_non_negative_int "$min_kbit" || [[ "$min_kbit" -eq 0 ]]; then
    min_kbit=128
  fi

  overlaps="$(detect_rule_port_proto_overlaps)"
  if [[ -n "$overlaps" ]]; then
    print_err "Conflict guard: overlapping enabled rules detected (same port/proto in multiple rules)."
    while IFS='|' read -r port proto ids; do
      [[ -n "${port:-}" ]] || continue
      echo "  - port=$port proto=$proto rules=$ids"
    done <<<"$overlaps"
    failed=1
  fi

  ip_overlaps="$(detect_ip_rule_exact_overlaps)"
  if [[ -n "$ip_overlaps" ]]; then
    print_warn "Conflict guard: duplicate enabled IP rules detected (same CIDRs+ports+proto)."
    while IFS='|' read -r cidrs ports proto ids; do
      [[ -n "${cidrs:-}" ]] || continue
      echo "  - cidrs=$cidrs ports=$ports proto=$proto rules=$ids"
    done <<<"$ip_overlaps"
  fi

  if [[ "$(count_enabled_ip_rules)" -gt 0 ]] && ! has_command nft; then
    print_err "Conflict guard: nft command is required when any IP/CIDR rule is enabled."
    failed=1
  fi

  local id enabled name ports proto down up burst created updated
  local resolved eff_down eff_up eff_burst source sid label p port
  while IFS='|' read -r id enabled name ports proto down up burst created updated; do
    [[ "$enabled" == "1" ]] || continue
    ports="$(normalize_ports "$ports")"
    [[ -n "$ports" ]] || continue
    validate_proto "$proto" || continue

    if ! is_non_negative_int "$down"; then down=0; fi
    if ! is_non_negative_int "$up"; then up=0; fi
    if ! is_non_negative_int "$burst"; then burst=32; fi
    [[ "$burst" -eq 0 ]] && burst=32

    resolved="$(resolve_effective_limits "$id" "$down" "$up" "$burst")"
    IFS='|' read -r eff_down eff_up eff_burst source sid label <<<"$resolved"

    for port in ${ports//,/ }; do
      for p in $(proto_words "$proto"); do
        [[ "$p" == "tcp" ]] || continue
        is_port_protected "$port" || continue
        if (( eff_down < min_kbit || eff_up < min_kbit )); then
          print_err "Conflict guard: protected port $port (rule $id) has low effective limit down=$eff_down up=$eff_up kbit (min=$min_kbit)."
          failed=1
        fi
      done
    done
  done < <(rules_lines)

  local iid i_enabled i_name i_cidrs i_ports i_proto i_down i_up i_burst i_created i_updated
  while IFS='|' read -r iid i_enabled i_name i_cidrs i_ports i_proto i_down i_up i_burst i_created i_updated; do
    [[ "$i_enabled" == "1" ]] || continue
    validate_proto "$i_proto" || continue
    is_non_negative_int "$i_down" || i_down=0
    is_non_negative_int "$i_up" || i_up=0

    local check_protected=0
    if [[ "$i_ports" == "any" || "$i_ports" == "*" || -z "$i_ports" ]]; then
      check_protected=1
    else
      local pp
      for pp in ${i_ports//,/ }; do
        if is_port_protected "$pp"; then
          check_protected=1
          break
        fi
      done
    fi

    if [[ "$check_protected" -eq 1 ]]; then
      if [[ "$i_proto" == "tcp" || "$i_proto" == "both" ]]; then
        if (( i_down < min_kbit || i_up < min_kbit )); then
          print_err "Conflict guard: protected-port safety violated by IP rule $iid (down=$i_down up=$i_up kbit, min=$min_kbit)."
          failed=1
        fi
      fi
    fi
  done < <(ip_rules_lines)

  same_prio="$(detect_schedule_same_priority_groups)"
  if [[ -n "$same_prio" ]]; then
    print_warn "Schedule guard: multiple enabled schedules share same rule+priority. Behavior is deterministic but easy to misconfigure."
    while IFS='|' read -r rid prio sids; do
      [[ -n "${rid:-}" ]] || continue
      echo "  - rule=$rid priority=$prio schedules=$sids"
    done <<<"$same_prio"
  fi

  if [[ "$failed" -ne 0 ]]; then
    print_err "Conflict guard blocked apply."
    return 1
  fi
  print_ok "Conflict guard passed."
  return 0
}

create_policy_snapshot() {
  local label="${1:-manual}"
  local sid dir
  sid="$(date +%Y%m%d-%H%M%S)"
  dir="$SNAPSHOTS_DIR/$sid"
  if [[ -d "$dir" ]]; then
    sid="${sid}-$$"
    dir="$SNAPSHOTS_DIR/$sid"
  fi

  mkdir -p "$dir" || return 1
  [[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "$dir/config" >/dev/null 2>&1 || true
  [[ -f "$RULES_DB" ]] && cp "$RULES_DB" "$dir/rules.db" >/dev/null 2>&1 || true
  [[ -f "$SCHEDULES_DB" ]] && cp "$SCHEDULES_DB" "$dir/schedules.db" >/dev/null 2>&1 || true
  [[ -f "$IPRULES_DB" ]] && cp "$IPRULES_DB" "$dir/iprules.db" >/dev/null 2>&1 || true

  {
    echo "id=$sid"
    echo "created_at=$(ts)"
    echo "label=$label"
    echo "interface=${INTERFACE:-N/A}"
    echo "ifb=${IFB_DEV:-N/A}"
    echo "rules=$(count_saved_rules)"
    echo "schedules=$(count_saved_schedules)"
    echo "ip_rules=$(count_saved_ip_rules)"
  } >"$dir/meta.env"

  if [[ -n "${INTERFACE:-}" ]]; then
    tc qdisc show dev "$INTERFACE" >"$dir/tc-main.qdisc" 2>/dev/null || true
    tc class show dev "$INTERFACE" >"$dir/tc-main.class" 2>/dev/null || true
    tc filter show dev "$INTERFACE" parent 1: >"$dir/tc-main.filter" 2>/dev/null || true
  fi
  tc qdisc show dev "$IFB_DEV" >"$dir/tc-ifb.qdisc" 2>/dev/null || true
  tc class show dev "$IFB_DEV" >"$dir/tc-ifb.class" 2>/dev/null || true
  tc filter show dev "$IFB_DEV" parent 2: >"$dir/tc-ifb.filter" 2>/dev/null || true

  echo "$sid"
}

list_snapshots() {
  local found=0 dir sid label created
  printf "%-24s %-20s %-28s\n" "SNAPSHOT_ID" "CREATED_AT" "LABEL"
  printf "%-24s %-20s %-28s\n" "------------------------" "--------------------" "----------------------------"
  while IFS= read -r dir; do
    found=1
    sid="$(basename "$dir")"
    label="-"
    created="-"
    if [[ -f "$dir/meta.env" ]]; then
      label="$(grep -E '^label=' "$dir/meta.env" | head -n1 | cut -d'=' -f2-)"
      created="$(grep -E '^created_at=' "$dir/meta.env" | head -n1 | cut -d'=' -f2-)"
      [[ -z "$label" ]] && label="-"
      [[ -z "$created" ]] && created="-"
    fi
    printf "%-24s %-20s %-28s\n" "$sid" "$created" "$label"
  done < <(find "$SNAPSHOTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
  if [[ "$found" -eq 0 ]]; then
    echo "No snapshots found."
  fi
}

restore_policy_snapshot_files() {
  local sid="$1"
  local dir="$SNAPSHOTS_DIR/$sid"
  [[ -d "$dir" ]] || {
    print_err "Snapshot not found: $sid"
    return 1
  }

  [[ -f "$dir/config" ]] && cp "$dir/config" "$CONFIG_FILE"
  [[ -f "$dir/rules.db" ]] && cp "$dir/rules.db" "$RULES_DB"
  [[ -f "$dir/schedules.db" ]] && cp "$dir/schedules.db" "$SCHEDULES_DB"
  [[ -f "$dir/iprules.db" ]] && cp "$dir/iprules.db" "$IPRULES_DB"
  load_config
  return 0
}

rollback_to_snapshot() {
  local sid="$1"
  restore_policy_snapshot_files "$sid" || return 1
  apply_enabled_rules 1 || {
    print_err "Rollback applied files but tc apply failed."
    return 1
  }
  print_ok "Rollback completed from snapshot: $sid"
  return 0
}

latest_snapshot_id() {
  find "$SNAPSHOTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | head -n1 | awk -F'/' '{print $NF}'
}

rollback_latest_snapshot() {
  local sid
  sid="$(latest_snapshot_id)"
  if [[ -z "$sid" ]]; then
    print_err "No snapshots available."
    return 1
  fi
  rollback_to_snapshot "$sid"
}

safe_apply() {
  local sid
  run_conflict_guard || return 1

  sid="$(create_policy_snapshot "safe-apply-pre")" || {
    print_err "Could not create snapshot."
    return 1
  }
  print_ok "Snapshot created: $sid"

  if apply_enabled_rules 1; then
    print_ok "Safe apply completed."
    return 0
  fi

  print_err "Apply failed. Rolling back to snapshot $sid..."
  rollback_to_snapshot "$sid"
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

validate_ports_or_any() {
  local v
  v="$(echo "${1:-}" | tr -d '[:space:]')"
  if [[ -z "$v" || "$v" == "any" || "$v" == "*" ]]; then
    return 0
  fi
  validate_ports "$v"
}

normalize_ports_or_any() {
  local v
  v="$(echo "${1:-}" | tr -d '[:space:]')"
  if [[ -z "$v" || "$v" == "any" || "$v" == "*" ]]; then
    echo "any"
    return
  fi
  normalize_ports "$v"
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

is_valid_ipv4() {
  local ip="$1" IFS=.
  local -a o
  read -r -a o <<<"$ip"
  [[ ${#o[@]} -eq 4 ]] || return 1
  local x
  for x in "${o[@]}"; do
    [[ "$x" =~ ^[0-9]+$ ]] || return 1
    ((x >= 0 && x <= 255)) || return 1
  done
}

normalize_ipv4_cidr_token() {
  local token="$1" ip prefix
  token="$(echo "$token" | tr -d '[:space:]')"
  [[ -n "$token" ]] || return 1

  if [[ "$token" == */* ]]; then
    ip="${token%%/*}"
    prefix="${token##*/}"
    is_valid_ipv4 "$ip" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    ((prefix >= 0 && prefix <= 32)) || return 1
    echo "$ip/$prefix"
    return 0
  fi

  is_valid_ipv4 "$token" || return 1
  echo "$token/32"
}

validate_ipv4_cidrs() {
  local raw t
  raw="$(echo "${1:-}" | tr -d '[:space:]')"
  [[ -n "$raw" ]] || return 1
  IFS=',' read -r -a _cidrs <<<"$raw"
  for t in "${_cidrs[@]}"; do
    normalize_ipv4_cidr_token "$t" >/dev/null || return 1
  done
}

normalize_ipv4_cidrs() {
  local raw t
  raw="$(echo "${1:-}" | tr -d '[:space:]')"
  IFS=',' read -r -a _cidrs <<<"$raw"
  for t in "${_cidrs[@]}"; do
    normalize_ipv4_cidr_token "$t" || true
  done | sort -u | paste -sd, -
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

next_ip_rule_id() {
  local max_id
  max_id="$(ip_rules_lines | awk -F'|' 'BEGIN{m=0} {if($1+0>m)m=$1+0} END{print m+0}')"
  echo $((max_id + 1))
}

get_ip_rule_by_id() {
  local iid="$1"
  ip_rules_lines | awk -F'|' -v x="$iid" '$1==x{print; exit}'
}

replace_ip_rule_line() {
  local iid="$1" new_line="$2" tmp_file
  tmp_file="$(mktemp)"
  awk -F'|' -v x="$iid" -v nl="$new_line" '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next}
  $1==x {print nl; found=1; next}
  {print}
  END {if(found!=1) exit 1}
  ' "$IPRULES_DB" >"$tmp_file" && mv "$tmp_file" "$IPRULES_DB"
}

delete_ip_rule_line() {
  local iid="$1" tmp_file
  tmp_file="$(mktemp)"
  awk -F'|' -v x="$iid" '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next}
  $1==x {found=1; next}
  {print}
  END {if(found!=1) exit 1}
  ' "$IPRULES_DB" >"$tmp_file" && mv "$tmp_file" "$IPRULES_DB"
}

list_ip_rules() {
  local count
  count="$(count_saved_ip_rules)"
  if [[ "$count" -eq 0 ]]; then
    echo "No saved IP/CIDR rules."
    return
  fi
  printf "%-4s %-7s %-18s %-24s %-12s %-8s %-8s %-8s %-8s\n" \
    "ID" "Status" "Name" "CIDRs" "Ports" "Proto" "Down" "Up" "Burst"
  printf "%-4s %-7s %-18s %-24s %-12s %-8s %-8s %-8s %-8s\n" \
    "----" "-------" "------------------" "------------------------" "------------" "--------" "--------" "--------" "--------"
  local iid enabled name cidrs ports proto down up burst created updated status
  while IFS='|' read -r iid enabled name cidrs ports proto down up burst created updated; do
    status="OFF"
    [[ "$enabled" == "1" ]] && status="ON"
    printf "%-4s %-7s %-18s %-24s %-12s %-8s %-8s %-8s %-8s\n" \
      "$iid" "$status" "$name" "${cidrs:0:24}" "$ports" "$proto" "$down" "$up" "$burst"
  done < <(ip_rules_lines)
}

add_ip_rule() {
  local iid name cidrs ports proto down up burst enabled now line
  iid="$(next_ip_rule_id)"
  name="$(sanitize_label "$(prompt_input "IP rule name" "iprule-$iid")")"

  while true; do
    cidrs="$(prompt_input "IPv4 / CIDR list (comma separated)" "")"
    if validate_ipv4_cidrs "$cidrs"; then
      cidrs="$(normalize_ipv4_cidrs "$cidrs")"
      break
    fi
    echo "Invalid IPv4/CIDR list. Example: 1.2.3.4,5.6.7.0/24"
  done

  while true; do
    ports="$(prompt_input "Service ports (comma separated or 'any')" "any")"
    if validate_ports_or_any "$ports"; then
      ports="$(normalize_ports_or_any "$ports")"
      break
    fi
    echo "Invalid ports."
  done

  while true; do
    proto="$(to_lower "$(prompt_input "Protocol (tcp|udp|both)" "both")")"
    validate_proto "$proto" && break
    echo "Invalid protocol."
  done

  down="$(prompt_non_negative_int "Download limit (kbit, 0=off)" "0")"
  up="$(prompt_non_negative_int "Upload limit (kbit, 0=off)" "0")"
  if [[ "$down" -eq 0 && "$up" -eq 0 ]]; then
    print_err "Both download and upload cannot be 0."
    return 1
  fi

  burst="$(prompt_non_negative_int "Burst (kb)" "32")"
  [[ "$burst" -eq 0 ]] && burst=32

  if prompt_yes_no "Enable this IP rule now?" "y"; then
    enabled=1
  else
    enabled=0
  fi

  now="$(ts)"
  line="$iid|$enabled|$name|$cidrs|$ports|$proto|$down|$up|$burst|$now|$now"
  echo "$line" >>"$IPRULES_DB"
  print_ok "IP rule $iid saved."
}

edit_ip_rule() {
  local iid line enabled name cidrs ports proto down up burst created updated now
  list_ip_rules
  echo
  iid="$(prompt_input "IP rule ID to edit")"
  line="$(get_ip_rule_by_id "$iid")"
  if [[ -z "$line" ]]; then
    print_err "IP rule not found."
    return 1
  fi
  IFS='|' read -r iid enabled name cidrs ports proto down up burst created updated <<<"$line"

  name="$(sanitize_label "$(prompt_input "IP rule name" "$name")")"
  while true; do
    cidrs="$(prompt_input "IPv4 / CIDR list (comma separated)" "$cidrs")"
    if validate_ipv4_cidrs "$cidrs"; then
      cidrs="$(normalize_ipv4_cidrs "$cidrs")"
      break
    fi
    echo "Invalid IPv4/CIDR list."
  done
  while true; do
    ports="$(prompt_input "Service ports (comma separated or 'any')" "$ports")"
    if validate_ports_or_any "$ports"; then
      ports="$(normalize_ports_or_any "$ports")"
      break
    fi
    echo "Invalid ports."
  done
  while true; do
    proto="$(to_lower "$(prompt_input "Protocol (tcp|udp|both)" "$proto")")"
    validate_proto "$proto" && break
    echo "Invalid protocol."
  done

  down="$(prompt_non_negative_int "Download limit (kbit, 0=off)" "$down")"
  up="$(prompt_non_negative_int "Upload limit (kbit, 0=off)" "$up")"
  if [[ "$down" -eq 0 && "$up" -eq 0 ]]; then
    print_err "Both download and upload cannot be 0."
    return 1
  fi

  burst="$(prompt_non_negative_int "Burst (kb)" "$burst")"
  [[ "$burst" -eq 0 ]] && burst=32
  now="$(ts)"
  replace_ip_rule_line "$iid" "$iid|$enabled|$name|$cidrs|$ports|$proto|$down|$up|$burst|$created|$now" || {
    print_err "Failed to update IP rule."
    return 1
  }
  print_ok "IP rule $iid updated."
}

set_ip_rule_enabled() {
  local iid="$1" target="$2"
  local line enabled name cidrs ports proto down up burst created updated
  line="$(get_ip_rule_by_id "$iid")"
  if [[ -z "$line" ]]; then
    print_err "IP rule not found."
    return 1
  fi
  IFS='|' read -r iid enabled name cidrs ports proto down up burst created updated <<<"$line"
  replace_ip_rule_line "$iid" "$iid|$target|$name|$cidrs|$ports|$proto|$down|$up|$burst|$created|$(ts)" || {
    print_err "Failed to update IP rule state."
    return 1
  }
  if [[ "$target" == "1" ]]; then
    print_ok "IP rule $iid enabled."
  else
    print_ok "IP rule $iid disabled."
  fi
}

delete_ip_rule() {
  local iid
  list_ip_rules
  echo
  iid="$(prompt_input "IP rule ID to delete")"
  if ! prompt_yes_no "Delete IP rule $iid ?" "n"; then
    echo "Cancelled."
    return 0
  fi
  delete_ip_rule_line "$iid" || {
    print_err "IP rule not found."
    return 1
  }
  print_ok "IP rule $iid deleted."
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
  clear_nft_policy
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

nft_table_exists() {
  has_command nft || return 1
  nft list table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1
}

clear_nft_policy() {
  if nft_table_exists; then
    nft delete table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1 || true
  fi
}

ensure_nft_base() {
  has_command nft || {
    print_err "nft command is required for IP/CIDR limiting."
    return 1
  }

  clear_nft_policy
  nft add table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1 || return 1
  nft add chain "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" prerouting "{ type filter hook prerouting priority mangle; policy accept; }" >/dev/null 2>&1 || return 1
  nft add chain "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" output "{ type route hook output priority mangle; policy accept; }" >/dev/null 2>&1 || return 1
  return 0
}

tc_add_fw_filter() {
  local dev="$1" parent="$2" mark="$3" classid="$4" prio="$5"
  tc filter add dev "$dev" parent "$parent" protocol ip prio "$prio" handle "$mark" fw flowid "$classid" >/dev/null 2>&1
}

nft_csv_to_set_expr() {
  local csv="$1"
  local formatted
  formatted="$(echo "$csv" | tr -d '[:space:]' | sed 's/,/, /g')"
  if [[ "$formatted" == *,* ]]; then
    echo "{ $formatted }"
  else
    echo "$formatted"
  fi
}

nft_exec_cmd() {
  local cmd="$1"
  nft -f - >/dev/null 2>&1 <<EOF
$cmd
EOF
}

nft_add_mark_rule() {
  local chain="$1" cidrs="$2" proto="$3" ports="$4" mark="$5" direction="$6"
  local addr_field port_field addr_expr port_expr cmd
  addr_expr="$(nft_csv_to_set_expr "$cidrs")"

  if [[ "$direction" == "download" ]]; then
    addr_field="saddr"
    port_field="dport"
  else
    addr_field="daddr"
    port_field="sport"
  fi

  if [[ "$ports" == "any" ]]; then
    cmd="add rule $NFT_TABLE_FAMILY $NFT_TABLE_NAME $chain ip $addr_field $addr_expr meta l4proto $proto meta mark set $mark"
    nft_exec_cmd "$cmd"
    return $?
  fi

  port_expr="$(nft_csv_to_set_expr "$ports")"
  cmd="add rule $NFT_TABLE_FAMILY $NFT_TABLE_NAME $chain ip $addr_field $addr_expr $proto $port_field $port_expr meta mark set $mark"
  nft_exec_cmd "$cmd"
}

apply_ip_rules_with_marks() {
  local cid_up_ref="$1"
  local cid_down_ref="$2"
  local prio_up_ref="$3"
  local prio_down_ref="$4"
  local mark_seed=1000
  local has_enabled=0

  if [[ "$(count_enabled_ip_rules)" -eq 0 ]]; then
    clear_nft_policy
    return 0
  fi

  ensure_nft_base || return 1

  local cid_up cid_down prio_up prio_down
  cid_up="$cid_up_ref"
  cid_down="$cid_down_ref"
  prio_up="$prio_up_ref"
  prio_down="$prio_down_ref"

  local iid enabled name cidrs ports proto down up burst created updated
    local p up_mark down_mark class_up class_down

  while IFS='|' read -r iid enabled name cidrs ports proto down up burst created updated; do
    [[ "$enabled" == "1" ]] || continue
    has_enabled=1

    cidrs="$(normalize_ipv4_cidrs "$cidrs")"
    [[ -n "$cidrs" ]] || continue
    validate_proto "$proto" || continue
    ports="$(normalize_ports_or_any "$ports")"
    [[ -n "$ports" ]] || ports="any"
    is_non_negative_int "$down" || down=0
    is_non_negative_int "$up" || up=0
    is_non_negative_int "$burst" || burst=32
    [[ "$burst" -eq 0 ]] && burst=32

    up_mark=$((mark_seed + iid * 2))
    down_mark=$((mark_seed + iid * 2 + 1))

    if [[ "$up" -gt 0 ]]; then
      class_up="1:$cid_up"
      tc class replace dev "$INTERFACE" parent 1:1 classid "$class_up" htb \
        rate "${up}kbit" ceil "${up}kbit" burst "${burst}kb" || continue
      tc_add_fw_filter "$INTERFACE" "1:" "$up_mark" "$class_up" "$prio_up" || true
      ((prio_up++))
      ((cid_up++))
    fi

    if [[ "$down" -gt 0 ]]; then
      class_down="2:$cid_down"
      tc class replace dev "$IFB_DEV" parent 2:1 classid "$class_down" htb \
        rate "${down}kbit" ceil "${down}kbit" burst "${burst}kb" || continue
      tc_add_fw_filter "$IFB_DEV" "2:" "$down_mark" "$class_down" "$prio_down" || true
      ((prio_down++))
      ((cid_down++))
    fi

    for p in $(proto_words "$proto"); do
      if [[ "$up" -gt 0 ]]; then
        nft_add_mark_rule "output" "$cidrs" "$p" "$ports" "$up_mark" "upload" || true
      fi
      if [[ "$down" -gt 0 ]]; then
        nft_add_mark_rule "prerouting" "$cidrs" "$p" "$ports" "$down_mark" "download" || true
      fi
    done
  done < <(ip_rules_lines)

  if [[ "$has_enabled" -eq 0 ]]; then
    clear_nft_policy
  fi

  printf -v "$cid_up_ref" '%s' "$cid_up"
  printf -v "$cid_down_ref" '%s' "$cid_down"
  printf -v "$prio_up_ref" '%s' "$prio_up"
  printf -v "$prio_down_ref" '%s' "$prio_down"
  return 0
}

build_effective_signature() {
  {
    echo "interface=${INTERFACE}"
    echo "ifb=${IFB_DEV}"
    echo "link_ceil=${LINK_CEIL}"
    echo "protected_ports=${PROTECTED_PORTS}"
    echo "min_protected_kbit=${MIN_PROTECTED_KBIT}"
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

    local iid i_enabled i_name i_cidrs i_ports i_proto i_down i_up i_burst i_created i_updated
    while IFS='|' read -r iid i_enabled i_name i_cidrs i_ports i_proto i_down i_up i_burst i_created i_updated; do
      [[ "$i_enabled" == "1" ]] || continue
      i_cidrs="$(normalize_ipv4_cidrs "$i_cidrs")"
      i_ports="$(normalize_ports_or_any "$i_ports")"
      validate_proto "$i_proto" || continue
      is_non_negative_int "$i_down" || i_down=0
      is_non_negative_int "$i_up" || i_up=0
      is_non_negative_int "$i_burst" || i_burst=32
      [[ "$i_burst" -eq 0 ]] && i_burst=32
      echo "iprule=${iid}|cidrs=${i_cidrs}|ports=${i_ports}|proto=${i_proto}|down=${i_down}|up=${i_up}|burst=${i_burst}"
    done < <(ip_rules_lines)
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
  local skip_guard="${1:-0}"
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

  if [[ "$skip_guard" != "1" ]]; then
    run_conflict_guard || return 1
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

  apply_ip_rules_with_marks cid_up cid_down prio_up prio_down || {
    print_err "Failed to apply IP/CIDR mark-based policies."
    return 1
  }

  print_ok "Applied enabled rules on $INTERFACE (ifb: $IFB_DEV)."
  log_msg "INFO" "Applied tc rules enabled_rules=$(count_enabled_rules) enabled_ip_rules=$(count_enabled_ip_rules)"
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
    echo "protected_ports: ${PROTECTED_PORTS:-none}"
    echo "min_protected_kbit: ${MIN_PROTECTED_KBIT}"
    echo "schedules: saved=$(count_saved_schedules) enabled=$(count_enabled_schedules) active_now=$(count_active_schedules_now)"
    echo "ip_rules: saved=$(count_saved_ip_rules) enabled=$(count_enabled_ip_rules)"
    echo "snapshots: $(count_snapshots)"
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
    echo "=== ip rules db ==="
    cat "$IPRULES_DB" 2>/dev/null || true
    echo
    echo "=== conflict guard ==="
    run_conflict_guard || true
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
    if has_command nft; then
      echo "=== nft table (${NFT_TABLE_FAMILY} ${NFT_TABLE_NAME}) ==="
      nft list table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" 2>/dev/null || true
      echo
    fi
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

set_protected_ports_config() {
  local value
  while true; do
    value="$(prompt_input "Protected ports (comma separated, empty=disable)" "$PROTECTED_PORTS")"
    value="$(echo "$value" | tr -d '[:space:]')"
    if [[ -z "$value" ]]; then
      PROTECTED_PORTS=""
      save_config
      print_warn "Protected ports disabled."
      return 0
    fi
    if validate_ports "$value"; then
      PROTECTED_PORTS="$(normalize_ports "$value")"
      save_config
      print_ok "Protected ports set: $PROTECTED_PORTS"
      return 0
    fi
    echo "Invalid port list."
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
  local choice value sid
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
    echo "[9] Safe apply (snapshot + rollback on fail)"
    echo "[10] Run conflict guard check"
    echo "[11] Set protected ports"
    echo "[12] Set minimum protected kbit"
    echo "[13] List snapshots"
    echo "[14] Rollback latest snapshot"
    echo "[15] Rollback selected snapshot"
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
      9) safe_apply; pause_enter ;;
      10) run_conflict_guard; pause_enter ;;
      11) set_protected_ports_config; pause_enter ;;
      12)
        value="$(prompt_non_negative_int "Minimum protected kbit" "$MIN_PROTECTED_KBIT")"
        if [[ "$value" -eq 0 ]]; then
          print_warn "0 is not allowed for protected minimum. Keeping previous value."
        else
          MIN_PROTECTED_KBIT="$value"
          save_config
          print_ok "Minimum protected kbit set to $MIN_PROTECTED_KBIT"
        fi
        pause_enter
        ;;
      13) list_snapshots; pause_enter ;;
      14) rollback_latest_snapshot; pause_enter ;;
      15)
        list_snapshots
        sid="$(prompt_input "Snapshot ID to rollback")"
        rollback_to_snapshot "$sid"
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
    echo "[9] IP/CIDR rules"
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
      9) ip_rules_menu ;;
      0) return ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

ip_rules_menu() {
  local choice iid
  while true; do
    menu_header "IP/CIDR Rules"
    echo "Saved IP rules : $(count_saved_ip_rules)"
    echo "Enabled        : $(count_enabled_ip_rules)"
    echo
    echo "[1] List IP rules"
    echo "[2] Add IP/CIDR rule"
    echo "[3] Edit IP/CIDR rule"
    echo "[4] Enable IP/CIDR rule"
    echo "[5] Disable IP/CIDR rule"
    echo "[6] Delete IP/CIDR rule"
    echo "[7] Apply enabled policies now"
    echo "[0] Back"
    choice="$(prompt_input "Choice")"
    case "$choice" in
      1) list_ip_rules; pause_enter ;;
      2) add_ip_rule; pause_enter ;;
      3) edit_ip_rule; pause_enter ;;
      4)
        list_ip_rules
        iid="$(prompt_input "IP rule ID to enable")"
        set_ip_rule_enabled "$iid" "1"
        pause_enter
        ;;
      5)
        list_ip_rules
        iid="$(prompt_input "IP rule ID to disable")"
        set_ip_rule_enabled "$iid" "0"
        pause_enter
        ;;
      6) delete_ip_rule; pause_enter ;;
      7) apply_enabled_rules; pause_enter ;;
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
  local selected_interface default_interface saved enabled disabled ip_saved ip_enabled schedules schedules_active snapshots detected detected_source ifb_state host_name up_text
  selected_interface="${INTERFACE:-N/A}"
  default_interface="$(detect_default_interface || true)"
  saved="$(count_saved_rules)"
  enabled="$(count_enabled_rules)"
  disabled="$(count_disabled_rules)"
  ip_saved="$(count_saved_ip_rules)"
  ip_enabled="$(count_enabled_ip_rules)"
  schedules="$(count_saved_schedules)"
  schedules_active="$(count_active_schedules_now)"
  snapshots="$(count_snapshots)"
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
  printf "   IP/CIDR Rules  : %s (enabled: %s)\n" "$ip_saved" "$ip_enabled"
  printf "   Schedules      : %s (active now: %s)\n" "$schedules" "$schedules_active"
  printf "   Snapshots      : %s\n" "$snapshots"
  printf "   Protected Ports: %s (min %skbit)\n" "${PROTECTED_PORTS:-none}" "${MIN_PROTECTED_KBIT}"
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
  $APP_NAME --safe-apply     # snapshot + guarded apply + auto rollback on failure
  $APP_NAME --tick           # apply only if schedule state changed
  $APP_NAME --clear          # clear tc rules
  $APP_NAME --status         # show tc status
  $APP_NAME --list           # list saved rules
  $APP_NAME --list-ip-rules  # list saved IP/CIDR rules
  $APP_NAME --list-schedules # list saved schedule windows
  $APP_NAME --conflict-check # validate conflicts and protected-port safety
  $APP_NAME --list-snapshots # list stored policy snapshots
  $APP_NAME --rollback-latest
  $APP_NAME --rollback-snapshot <snapshot_id>
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
    --safe-apply)
      require_root
      require_commands
      safe_apply
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
    --list-ip-rules)
      list_ip_rules
      exit 0
      ;;
    --list-schedules)
      list_schedules
      exit 0
      ;;
    --conflict-check)
      require_root
      require_commands
      run_conflict_guard
      exit $?
      ;;
    --list-snapshots)
      list_snapshots
      exit 0
      ;;
    --rollback-latest)
      require_root
      require_commands
      rollback_latest_snapshot
      exit $?
      ;;
    --rollback-snapshot)
      require_root
      require_commands
      if [[ -z "${2:-}" ]]; then
        print_err "Missing snapshot id."
        exit 1
      fi
      rollback_to_snapshot "$2"
      exit $?
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
