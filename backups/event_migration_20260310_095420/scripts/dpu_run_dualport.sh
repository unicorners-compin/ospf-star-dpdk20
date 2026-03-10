#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
DPU_HOST="${DPU_HOST:-192.168.0.50}"
DPU_USER="${DPU_USER:-admin}"
DPU_PASS="${DPU_PASS:-admin}"
DPU_DIR="${DPU_DIR:-/home/admin/ospf-star-dpdk20-dpu}"
SUDO_PASS="${SUDO_PASS:-$DPU_PASS}"

# DPU data ports by spec
INGRESS_IF="${INGRESS_IF:-net_af_packet0}"
EGRESS_IF="${EGRESS_IF:-net_af_packet1}"
RULES_PATH="${RULES_PATH:-${DPU_DIR}/configs/rules.json}"
EAL_CPUSET="${EAL_CPUSET:-2-3}"
EAL_EXTRA="${EAL_EXTRA:-}"
EAL_DEV_ARGS="${EAL_DEV_ARGS:-}"
APP_EXTRA="${APP_EXTRA:-}"
APP_MODE="${APP_MODE:-poll}"
EVENT_STRICT="${EVENT_STRICT:-0}"
LOG_PATH="${LOG_PATH:-${DPU_DIR}/logs/dpu-dualport-l2.log}"
PID_PATH="${PID_PATH:-${DPU_DIR}/logs/dpu-dualport-l2.pid}"
RULES_LOCAL="${RULES_LOCAL:-}"

if [[ "${APP_MODE}" == "event" ]]; then
  APP_EXTRA="${APP_EXTRA} --mode event"
else
  APP_EXTRA="${APP_EXTRA} --mode poll"
fi
if [[ "${EVENT_STRICT}" == "1" ]]; then
  APP_EXTRA="${APP_EXTRA} --event-strict"
fi

if [[ -z "${EAL_EXTRA}" ]]; then
  # Default: keep old AF_PACKET vdev mode for safe fallback.
  EAL_EXTRA="--file-prefix=dpudualport --no-huge -m 256 --vdev=net_af_packet0,iface=eth0 --vdev=net_af_packet1,iface=eth1"
fi
# Optional: pass explicit PCI devices (for real event mode, e.g. -a NIC -a EVENTDEV).
if [[ -n "${EAL_DEV_ARGS}" ]]; then
  EAL_EXTRA="${EAL_EXTRA} ${EAL_DEV_ARGS}"
fi

run_remote() {
  sshpass -p "${DPU_PASS}" ssh -T -o StrictHostKeyChecking=no "${DPU_USER}@${DPU_HOST}" "$1"
}

remote_sudo() {
  local cmd="$1"
  run_remote "
    set -e
    if command -v sudo >/dev/null 2>&1; then
      if sudo -n true >/dev/null 2>&1; then
        sudo -n bash -lc \"$cmd\"
      else
        printf '%s\n' '${SUDO_PASS}' | sudo -S -p '' bash -lc \"$cmd\"
      fi
    else
      bash -lc \"$cmd\"
    fi
  "
}

case "${ACTION}" in
  start)
    remote_sudo "
      PATH=\$PATH:/sbin:/usr/sbin
      [ -x '${DPU_DIR}/core/dpu-dualport-l2' ]
      mkdir -p '${DPU_DIR}/logs'
      nohup '${DPU_DIR}/core/dpu-dualport-l2' -l ${EAL_CPUSET} ${EAL_EXTRA} -- --ingress ${INGRESS_IF} --egress ${EGRESS_IF} --rules '${RULES_PATH}' ${APP_EXTRA} > '${LOG_PATH}' 2>&1 & echo \$! > '${PID_PATH}'
      sleep 1
      if [ -f '${PID_PATH}' ]; then
        pid=\$(cat '${PID_PATH}' 2>/dev/null || true)
        if [ -n \"\$pid\" ] && echo \"\$pid\" | grep -Eq '^[0-9]+$'; then
          ps -fp \"\$pid\" || true
        fi
      fi
      tail -n 20 '${LOG_PATH}' || true
    "
    ;;
  stop)
    remote_sudo "
      if [ -f '${PID_PATH}' ]; then
        pid=\$(cat '${PID_PATH}' 2>/dev/null || true)
        if [ -n \"\$pid\" ] && echo \"\$pid\" | grep -Eq '^[0-9]+$'; then
          kill \"\$pid\" 2>/dev/null || true
        fi
        rm -f '${PID_PATH}'
      fi
      pkill -f '^${DPU_DIR}/core/dpu-dualport-l2' 2>/dev/null || true
      pgrep -af '^${DPU_DIR}/core/dpu-dualport-l2' || true
    "
    ;;
  status)
    run_remote "
      set -e
      PATH=\$PATH:/sbin:/usr/sbin
      ip -br link show dev eth0 || true
      ip -br link show dev eth1 || true
      pgrep -af '^${DPU_DIR}/core/dpu-dualport-l2' || true
      [ -f '${LOG_PATH}' ] && tail -n 30 '${LOG_PATH}' || true
    "
    ;;
  reload)
    remote_sudo "
      pids=\$(pgrep -f '^${DPU_DIR}/core/dpu-dualport-l2' || true)
      if [ -n \"\$pids\" ]; then
        kill -HUP \$pids || true
      fi
      echo reload_sent
    "
    ;;
  sync-rules)
    if [ -z "${RULES_LOCAL}" ]; then
      RULES_LOCAL="${2:-}"
    fi
    if [ -z "${RULES_LOCAL}" ]; then
      echo "usage: $0 sync-rules <local_rules.json>" >&2
      exit 2
    fi
    sshpass -p "${DPU_PASS}" scp -o StrictHostKeyChecking=no "${RULES_LOCAL}" "${DPU_USER}@${DPU_HOST}:${RULES_PATH}"
    remote_sudo "
      ls -l '${RULES_PATH}'
      pids=\$(pgrep -f '^${DPU_DIR}/core/dpu-dualport-l2' || true)
      if [ -n \"\$pids\" ]; then
        kill -HUP \$pids || true
      fi
      echo rules_synced_and_reloaded
    "
    ;;
  *)
    echo "usage: $0 {start|stop|status|reload|sync-rules [local_rules.json]}" >&2
    exit 2
    ;;
esac
