#!/usr/bin/env bash

set -u

APP_NAME="limit-tc-port"
APP_AUTHOR="Behnam (@b3hnamrjd)"
CONFIG_DIR="/etc/limit-tc-port"
CONFIG_FILE="$CONFIG_DIR/config"
RULES_DB="$CONFIG_DIR/rules.db"
LOG_FILE="/var/log/limit-tc-port.log"
SERVICE_FILE="/etc/systemd/system/limit-tc-port.service"
BIN_PATH="/usr/local/bin/limit-tc-port"

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
  for cmd in tc ip ss awk sort uniq paste modprobe; do
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

ensure_storage() {
  mkdir -p "$CONFIG_DIR"
  touch "$LOG_FILE"
  if [[ ! -f "$RULES_DB" ]]; then
    cat >"$RULES_DB" <<'EOF'
# id|enabled|name|ports|proto|down_kbit|up_kbit|burst_kb|created_at|updated_at
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

detect_inbounds() {
  ss -H -lntu 2>/dev/null | awk '
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

detected_ports_csv() {
  detect_inbounds | cut -d'|' -f1 | paste -sd, -
}

print_detected_inbounds() {
  local found=0
  echo "Detected listening ports:"
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
    local proto_list class_up class_down p port

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
  install -m 0755 "$self_path" "$BIN_PATH"

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

  systemctl daemon-reload
  print_ok "Service installed/updated: $SERVICE_FILE"
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
  local choice
  if ! has_systemd; then
    print_err "systemctl not found. Service menu is unavailable."
    pause_enter
    return 1
  fi
  while true; do
    menu_header "Service Operations"
    echo "[I] Install/Update service files"
    echo "[E] Enable + Start service"
    echo "[R] Restart service"
    echo "[D] Disable + Stop service"
    echo "[S] Show service status"
    echo "[B] Back"
    choice="$(to_lower "$(prompt_input "Action" "b")")"
    case "$choice" in
      i) install_or_update_service; pause_enter ;;
      e) systemctl enable --now limit-tc-port.service && print_ok "Service enabled and started."; pause_enter ;;
      r) systemctl restart limit-tc-port.service && print_ok "Service restarted."; pause_enter ;;
      d) systemctl disable --now limit-tc-port.service && print_ok "Service stopped and disabled."; pause_enter ;;
      s) systemctl status --no-pager limit-tc-port.service || true; pause_enter ;;
      b|0) return ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

maintenance_menu() {
  local choice value
  while true; do
    menu_header "Maintenance Toolkit"
    echo "[A] Apply enabled rules now"
    echo "[C] Clear all tc rules"
    echo "[B] Backup rules"
    echo "[R] Restore rules from backup"
    echo "[N] Change interface"
    echo "[I] Set IFB device"
    echo "[L] Set link ceiling"
    echo "[Q] Back"
    choice="$(to_lower "$(prompt_input "Action")")"
    case "$choice" in
      a) apply_enabled_rules; pause_enter ;;
      c) clear_tc; print_ok "tc rules cleared."; pause_enter ;;
      b) backup_rules; pause_enter ;;
      r) restore_rules; pause_enter ;;
      n) pick_interface; pause_enter ;;
      i)
        value="$(prompt_input "IFB device name" "$IFB_DEV")"
        IFB_DEV="$value"
        save_config
        print_ok "IFB device set to $IFB_DEV"
        pause_enter
        ;;
      l)
        value="$(prompt_input "Link ceiling (example: 1000mbit)" "$LINK_CEIL")"
        LINK_CEIL="$value"
        save_config
        print_ok "Link ceiling set to $LINK_CEIL"
        pause_enter
        ;;
      q|0) return ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

rules_menu() {
  local choice id
  while true; do
    menu_header "Rules Studio"
    echo "[L] List rules"
    echo "[A] Add rule"
    echo "[E] Edit rule"
    echo "[N] Enable rule"
    echo "[F] Disable rule"
    echo "[D] Delete rule"
    echo "[P] Apply enabled rules"
    echo "[W] Quick wizard"
    echo "[B] Back"
    choice="$(to_lower "$(prompt_input "Action" "b")")"
    case "$choice" in
      l) list_rules; pause_enter ;;
      a) add_rule; pause_enter ;;
      e) edit_rule; pause_enter ;;
      n)
        list_rules
        id="$(prompt_input "Rule ID to enable")"
        set_rule_enabled "$id" "1"
        pause_enter
        ;;
      f)
        list_rules
        id="$(prompt_input "Rule ID to disable")"
        set_rule_enabled "$id" "0"
        pause_enter
        ;;
      d) delete_rule; pause_enter ;;
      p) apply_enabled_rules; pause_enter ;;
      w) quick_wizard; pause_enter ;;
      b|0) return ;;
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
    echo "[C] Create rule from detected ports"
    echo "[B] Back"
    choice="$(to_lower "$(prompt_input "Action" "b")")"
    case "$choice" in
      c)
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
      b|0) return ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

render_dashboard() {
  local selected_interface default_interface saved enabled disabled detected ifb_state host_name up_text
  selected_interface="${INTERFACE:-N/A}"
  default_interface="$(detect_default_interface || true)"
  saved="$(count_saved_rules)"
  enabled="$(count_enabled_rules)"
  disabled="$(count_disabled_rules)"
  detected="$(detected_ports_csv)"
  detected="${detected:-none}"
  ifb_state="$(ifb_status)"
  host_name="$(hostname 2>/dev/null || echo "server")"
  up_text="$(uptime -p 2>/dev/null || echo "uptime n/a")"
  if [[ "${#detected}" -gt 66 ]]; then
    detected="${detected:0:63}..."
  fi

  echo -e "${BLUE}======================================================================${RESET}"
  echo -e " ${MAGENTA}BWLimiter Control Center${RESET}   ${DIM}host:${host_name}${RESET}"
  echo -e " ${DIM}Developed by: ${APP_AUTHOR}${RESET}"
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
  printf "   Detected Ports : %s\n" "$detected"
  echo
  echo -e " ${CYAN}Runtime${RESET}"
  printf "   Uptime         : %s\n" "$up_text"
  printf "   Rules DB       : %s\n" "$RULES_DB"
  printf "   Log File       : %s\n" "$LOG_FILE"
  echo -e "${BLUE}----------------------------------------------------------------------${RESET}"
  echo " [R] Rules Studio   [I] Inbound Discovery   [S] Service Ops"
  echo " [M] Live Monitor   [T] Maintenance Toolkit [W] Quick Wizard"
  echo " [A] Apply Active   [Q] Quit"
}

show_help() {
  cat <<EOF
$APP_NAME - Port bandwidth manager using tc/ifb
Developed by: $APP_AUTHOR

Usage:
  $APP_NAME                  # interactive menu
  $APP_NAME --apply          # apply enabled rules
  $APP_NAME --clear          # clear tc rules
  $APP_NAME --status         # show tc status
  $APP_NAME --list           # list saved rules
  $APP_NAME --install-service
  $APP_NAME --help
EOF
}

main_menu() {
  local choice
  while true; do
    clear
    render_dashboard
    echo
    choice="$(to_lower "$(prompt_input "Action" "q")")"
    case "$choice" in
      r|1) rules_menu ;;
      i|2) detected_menu ;;
      s|3) service_menu ;;
      m|4) monitor_tc_live ;;
      t|5) maintenance_menu ;;
      w) quick_wizard; pause_enter ;;
      a) apply_enabled_rules; pause_enter ;;
      q|0|exit) exit 0 ;;
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
    --install-service)
      require_root
      require_commands
      install_or_update_service
      exit 0
      ;;
    "")
      require_root
      require_commands
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
