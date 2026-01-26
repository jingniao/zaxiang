#!/usr/bin/env bash
# =========================================================
# Debian 11 Monthly Traffic Monitor & Shaper (vnStat + tc)
# - One-click install: --install (creates systemd service)
# - Auto install deps
# - Manual limit: --limit-now [KBps]
# - Monthly auto reset: unlimit + re-arm
# - PushPlus notify on start/limit/unlimit/reset
# =========================================================

set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"

CONF="/etc/traffic_shaper.conf"
STATE_DIR="/var/lib/traffic_shaper"
STATE_FILE="$STATE_DIR/state"
LOCK_FILE="/run/traffic_shaper.lock"
mkdir -p "$STATE_DIR"

# ---------------- Default config ----------------
DEFAULT_IFACE="ens3"
DEFAULT_LIMIT_GB="100"
DEFAULT_MODE="either"          # up|down|both|either
DEFAULT_RATE_KBPS="10"         # KB/s (10KB/s)
DEFAULT_BURST_KB="20"          # KB

# PushPlus defaults (你的 token)
DEFAULT_PUSHPLUS_TOKEN="12762cf2998b47ffa4abe462b4d196bd"
DEFAULT_PUSHPLUS_TEMPLATE="html"
DEFAULT_NOTIFY_ON_RESET="1"
# -----------------------------------------------

require_root_and_install_deps() {
  if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 运行（sudo）"
    exit 1
  fi

  local REQUIRED_PKGS=(vnstat iproute2 jq whiptail curl python3)
  local missing=()
  for p in "${REQUIRED_PKGS[@]}"; do
    dpkg -s "$p" &>/dev/null || missing+=("$p")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "正在安装依赖: ${missing[*]}"
    apt update -y
    apt install -y "${missing[@]}"
  fi

  systemctl enable --now vnstat >/dev/null 2>&1 || true
}

load_conf() {
  if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
  fi

  IFACE="${IFACE:-$DEFAULT_IFACE}"
  LIMIT_GB="${LIMIT_GB:-$DEFAULT_LIMIT_GB}"
  MODE="${MODE:-$DEFAULT_MODE}"
  RATE_KBPS="${RATE_KBPS:-$DEFAULT_RATE_KBPS}"
  BURST_KB="${BURST_KB:-$DEFAULT_BURST_KB}"

  PUSHPLUS_TOKEN="${PUSHPLUS_TOKEN:-$DEFAULT_PUSHPLUS_TOKEN}"
  PUSHPLUS_TEMPLATE="${PUSHPLUS_TEMPLATE:-$DEFAULT_PUSHPLUS_TEMPLATE}"
  NOTIFY_ON_RESET="${NOTIFY_ON_RESET:-$DEFAULT_NOTIFY_ON_RESET}"
}

save_conf() {
  cat > "$CONF" <<EOF
# Traffic shaper config
IFACE="$IFACE"
LIMIT_GB="$LIMIT_GB"
MODE="$MODE"            # up|down|both|either
RATE_KBPS="$RATE_KBPS"  # KB/s
BURST_KB="$BURST_KB"    # KB

# PushPlus notify
PUSHPLUS_TOKEN="$PUSHPLUS_TOKEN"
PUSHPLUS_TEMPLATE="$PUSHPLUS_TEMPLATE"
NOTIFY_ON_RESET="$NOTIFY_ON_RESET"  # 1 notify monthly reset, 0 silent
EOF
}

urlencode() {
  python3 - <<'PY' "$1"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

notify_pushplus() {
  local title="$1"
  local content="$2"
  [[ -z "${PUSHPLUS_TOKEN:-}" ]] && return 0

  local t c tpl
  t=$(urlencode "$title")
  c=$(urlencode "$content")
  tpl=$(urlencode "${PUSHPLUS_TEMPLATE:-html}")

  curl -fsS --max-time 8 \
    "https://www.pushplus.plus/send?token=${PUSHPLUS_TOKEN}&title=${t}&content=${c}&template=${tpl}" \
    >/dev/null || true
}

human_bytes() {
  local b="$1"
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB",u," ");
    i=1;
    while(b>=1024 && i<5){b/=1024;i++}
    printf "%.2f %s", b, u[i];
  }'
}

# ---------- vnStat init + monthly bytes ----------
ensure_vnstat_iface() {
  # 如果 vnstat 没有这个 iface，会导致 json 里没有接口
  if ! vnstat --iflist 2>/dev/null | tr ' ' '\n' | grep -qx "$IFACE"; then
    vnstat -u -i "$IFACE" >/dev/null 2>&1 || true
    systemctl restart vnstat >/dev/null 2>&1 || true
  fi
}

get_month_bytes() {
  local y m out
  y=$(date +%Y)
  m=$(date +%-m)

  ensure_vnstat_iface

  out=$(vnstat --json | jq -r \
    --arg iface "$IFACE" \
    --argjson y "$y" \
    --argjson m "$m" '
    [ .interfaces[]? | select(.name == $iface)
      | (.traffic.month // .traffic.months // [])[]?
      | select(.date.year == $y and .date.month == $m)
      | "\(.rx) \(.tx)" ][0] // "0 0"
  ')
  echo "$out"
}

# ---------- tc shaping: egress + ingress(ifb) ----------
rate_to_kbit() { echo $((RATE_KBPS * 8)); }

ensure_ifb() {
  modprobe ifb >/dev/null 2>&1 || true
  ip link show ifb0 &>/dev/null || ip link add ifb0 type ifb
  ip link set ifb0 up

  tc qdisc show dev "$IFACE" | grep -q "ffff:" || \
    tc qdisc add dev "$IFACE" handle ffff: ingress

  tc filter show dev "$IFACE" parent ffff: 2>/dev/null | grep -q "mirred.*ifb0" || \
    tc filter add dev "$IFACE" parent ffff: protocol ip u32 match u32 0 0 \
      action mirred egress redirect dev ifb0
}

apply_limit() {
  local kbit
  kbit=$(rate_to_kbit)

  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc add dev "$IFACE" root tbf rate "${kbit}kbit" burst "${BURST_KB}kb" latency 400ms

  ensure_ifb
  tc qdisc del dev ifb0 root 2>/dev/null || true
  tc qdisc add dev ifb0 root tbf rate "${kbit}kbit" burst "${BURST_KB}kb" latency 400ms
}

remove_limit() {
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc del dev ifb0 root 2>/dev/null || true
}

# ---------- state: monthly reset ----------
read_state() {
  local cur_month
  cur_month=$(date +%Y-%m)

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  else
    month="$cur_month"
    triggered="0"
    started_notified="0"
    manual_limited="0"
  fi

  # 新月自动重置：解除限速 + 清状态
  if [[ "${month:-}" != "$cur_month" ]]; then
    month="$cur_month"
    triggered="0"
    manual_limited="0"
    remove_limit || true
    if [[ "${NOTIFY_ON_RESET:-1}" == "1" ]]; then
      notify_pushplus "新月已重置" "进入新月份（${month}），已自动解除限速并重置触发状态。"
    fi
  fi
}

write_state() {
  cat > "$STATE_FILE" <<EOF
month="$month"
triggered="$triggered"
started_notified="${started_notified:-0}"
manual_limited="${manual_limited:-0}"
EOF
}

limit_bytes() {
  awk -v g="$LIMIT_GB" 'BEGIN{printf "%.0f", g*1024*1024*1024}'
}

should_trigger() {
  local rx="$1" tx="$2"
  local lim
  lim=$(limit_bytes)

  case "$MODE" in
    up)     [[ "$tx" -ge "$lim" ]] ;;
    down)   [[ "$rx" -ge "$lim" ]] ;;
    both)   [[ $((rx+tx)) -ge "$lim" ]] ;;
    either) [[ "$rx" -ge "$lim" || "$tx" -ge "$lim" ]] ;;
    *)      [[ $((rx+tx)) -ge "$lim" ]] ;;
  esac
}

status_line() {
  local rx="$1" tx="$2"
  local sum=$((rx+tx))
  echo "IFACE=$IFACE MODE=$MODE LIMIT=${LIMIT_GB}GB RATE=${RATE_KBPS}KB/s RX=$(human_bytes "$rx") TX=$(human_bytes "$tx") SUM=$(human_bytes "$sum") TRIGGERED=$triggered MANUAL=$manual_limited MONTH=$month"
}

monitor_once() {
  load_conf
  read_state

  local rx tx
  read -r rx tx < <(get_month_bytes)

  # daemon 首次循环发“启动成功”
  if [[ "${RUN_CONTEXT:-}" == "daemon" && "${started_notified:-0}" == "0" ]]; then
    started_notified="1"
    notify_pushplus "启动成功" "traffic_shaper 已启动（IFACE=$IFACE, MODE=$MODE, LIMIT=${LIMIT_GB}GB, RATE=${RATE_KBPS}KB/s）。当前本月：RX=$(human_bytes "$rx") TX=$(human_bytes "$tx")。"
  fi

  # 如果是手动限速（manual_limited=1），就保持限速，但仍允许跨月重置
  if [[ "${manual_limited:-0}" == "1" ]]; then
    if ! tc qdisc show dev "$IFACE" 2>/dev/null | grep -q "tbf"; then
      apply_limit || true
    fi
    write_state
    status_line "$rx" "$tx"
    return 0
  fi

  # 自动触发逻辑
  if [[ "${triggered}" == "1" ]]; then
    if ! tc qdisc show dev "$IFACE" 2>/dev/null | grep -q "tbf"; then
      apply_limit || true
    fi
    write_state
    status_line "$rx" "$tx"
    return 0
  fi

  if should_trigger "$rx" "$tx"; then
    triggered="1"
    apply_limit
    notify_pushplus "流量超限已限速" "本月流量达到阈值（${LIMIT_GB}GB）。当前：RX=$(human_bytes "$rx") TX=$(human_bytes "$tx")；已对 $IFACE 上下行限速到 ${RATE_KBPS}KB/s。"
  fi

  write_state
  status_line "$rx" "$tx"
}

daemon_loop() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || { echo "Already running."; exit 0; }

  export RUN_CONTEXT="daemon"
  while true; do
    monitor_once || true
    sleep 60
  done
}

config_menu() {
  load_conf

  local ifaces iface_choice
  ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' || true)

  iface_choice=$(whiptail --title "Traffic Shaper" --menu "选择监控网卡（建议选主网卡，如 ens3/eth0）" 20 70 10 \
    $(echo "$ifaces" | awk '{print $1" "$1}') \
    3>&1 1>&2 2>&3) || exit 0
  IFACE="$iface_choice"

  local mode_choice
  mode_choice=$(whiptail --title "Traffic Shaper" --menu "选择监控流量类型" 20 70 10 \
    "up"     "上行流量 (TX) 达到阈值触发" \
    "down"   "下行流量 (RX) 达到阈值触发" \
    "both"   "双向流量 (RX+TX) 达到阈值触发" \
    "either" "上/下行任意一个先到阈值就触发" \
    3>&1 1>&2 2>&3) || exit 0
  MODE="$mode_choice"

  LIMIT_GB=$(whiptail --title "Traffic Shaper" --inputbox "输入每月流量阈值（GB，按1024^3计算）" 10 70 "$LIMIT_GB" 3>&1 1>&2 2>&3) || exit 0
  RATE_KBPS=$(whiptail --title "Traffic Shaper" --inputbox "超限后/手动限速 默认值（KB/s）" 10 70 "$RATE_KBPS" 3>&1 1>&2 2>&3) || exit 0

  save_conf
  whiptail --title "Traffic Shaper" --msgbox "配置已保存到 $CONF" 10 60
}

install_systemd() {
  cat >/etc/systemd/system/traffic-shaper.service <<EOF
[Unit]
Description=Monthly Traffic Monitor and Shaper (vnstat + tc)
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH --daemon
Restart=always
RestartSec=5
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now traffic-shaper.service
}

install_oneclick() {
  require_root_and_install_deps
  if [[ ! -f "$CONF" ]]; then
    config_menu
  else
    load_conf
  fi
  ensure_vnstat_iface
  install_systemd
  notify_pushplus "一键安装完成" "traffic_shaper 已安装并作为 systemd 服务运行。查看：systemctl status traffic-shaper"
  echo "✅ 已安装并启动。查看状态：systemctl status traffic-shaper"
}

status_cmd() {
  require_root_and_install_deps
  load_conf
  read_state
  local rx tx
  read -r rx tx < <(get_month_bytes)
  status_line "$rx" "$tx"
}

limit_now_cmd() {
  require_root_and_install_deps
  load_conf
  read_state

  # 可选：临时覆盖限速值
  if [[ -n "${1:-}" ]]; then
    if ! [[ "$1" =~ ^[0-9]+$ ]]; then
      echo "参数必须是整数 KB/s，例如：--limit-now 10"
      exit 1
    fi
    RATE_KBPS="$1"
  fi

  # 手动限速：设置 manual_limited=1（这样 daemon 会一直保持限速，直到你手动解除或跨月自动重置）
  manual_limited="1"
  triggered="0"
  apply_limit
  write_state

  notify_pushplus "已手动限速" "已对 $IFACE 上下行手动限速到 ${RATE_KBPS}KB/s。下个月会自动重置解除限速。"
  echo "Manual limit applied: ${RATE_KBPS}KB/s"
}

unlimit_cmd() {
  require_root_and_install_deps
  load_conf
  read_state
  remove_limit || true
  triggered="0"
  manual_limited="0"
  write_state
  notify_pushplus "已手动解除限速" "已解除 $IFACE 限速，并清除本月触发/手动限速状态。"
  echo "Unlimit done."
}

usage() {
  cat <<EOF
Usage:
  $0 --install               一键安装 + 配置 + systemd 开机自启 + 启动
  $0 --status                查看本月已用流量（RX/TX/SUM）与状态
  $0 --limit-now [KBps]      立刻手动限速（可选指定 KB/s），下个月自动重置解除
  $0 --unlimit               立刻解除限速（并清状态）
  $0 --config                重新交互配置
  $0 --daemon                systemd 调用：常驻监控（每60秒）
EOF
}

main() {
  case "${1:-}" in
    --install)  install_oneclick ;;
    --status)   status_cmd ;;
    --limit-now) shift; limit_now_cmd "${1:-}" ;;
    --unlimit)  unlimit_cmd ;;
    --config)   require_root_and_install_deps; config_menu ;;
    --daemon)   require_root_and_install_deps; daemon_loop ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
