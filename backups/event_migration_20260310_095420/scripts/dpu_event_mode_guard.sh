#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"  # snapshot|start-event|start-poll|rollback|status
DPU_HOST="${DPU_HOST:-192.168.0.52}"
DPU_USER="${DPU_USER:-admin}"
DPU_PASS="${DPU_PASS:-admin}"
DPU_DIR="${DPU_DIR:-/home/admin/ospf-star-dpdk20-dpu}"
RUN_SCRIPT="${RUN_SCRIPT:-/home/zyren/ospf-star-dpdk20/scripts/dpu_run_dualport.sh}"
SNAP_DIR="${SNAP_DIR:-${DPU_DIR}/snapshots/event_guard}"
SUDO_PASS="${SUDO_PASS:-$DPU_PASS}"

ssh_cmd() {
  sshpass -p "${DPU_PASS}" ssh -o StrictHostKeyChecking=no "${DPU_USER}@${DPU_HOST}" "$1"
}

case "${ACTION}" in
  snapshot)
    ssh_cmd "
      set -e
      mkdir -p '${SNAP_DIR}' '${DPU_DIR}/logs'
      ts=\$(date +%Y%m%d_%H%M%S)
      cp -f '${DPU_DIR}/core/dpu-dualport-l2' '${SNAP_DIR}/dpu-dualport-l2.'\"\$ts\" || true
      if [ -f '${DPU_DIR}/configs/rules.json' ]; then
        cp -f '${DPU_DIR}/configs/rules.json' '${SNAP_DIR}/rules.json.'\"\$ts\"
      fi
      printf 'SNAPSHOT_TS=%s\n' "\$ts" | tee '${SNAP_DIR}/LATEST'
      ls -1t '${SNAP_DIR}' | head -n 5
    "
    ;;
  start-event)
    DPU_HOST="${DPU_HOST}" DPU_USER="${DPU_USER}" DPU_PASS="${DPU_PASS}" DPU_DIR="${DPU_DIR}" SUDO_PASS="${SUDO_PASS}" APP_MODE=event EVENT_STRICT=0 "${RUN_SCRIPT}" stop
    DPU_HOST="${DPU_HOST}" DPU_USER="${DPU_USER}" DPU_PASS="${DPU_PASS}" DPU_DIR="${DPU_DIR}" SUDO_PASS="${SUDO_PASS}" APP_MODE=event EVENT_STRICT=0 "${RUN_SCRIPT}" start
    DPU_HOST="${DPU_HOST}" DPU_USER="${DPU_USER}" DPU_PASS="${DPU_PASS}" DPU_DIR="${DPU_DIR}" "${RUN_SCRIPT}" status
    ;;
  start-poll)
    DPU_HOST="${DPU_HOST}" DPU_USER="${DPU_USER}" DPU_PASS="${DPU_PASS}" DPU_DIR="${DPU_DIR}" SUDO_PASS="${SUDO_PASS}" APP_MODE=poll EVENT_STRICT=0 "${RUN_SCRIPT}" stop
    DPU_HOST="${DPU_HOST}" DPU_USER="${DPU_USER}" DPU_PASS="${DPU_PASS}" DPU_DIR="${DPU_DIR}" SUDO_PASS="${SUDO_PASS}" APP_MODE=poll EVENT_STRICT=0 "${RUN_SCRIPT}" start
    DPU_HOST="${DPU_HOST}" DPU_USER="${DPU_USER}" DPU_PASS="${DPU_PASS}" DPU_DIR="${DPU_DIR}" "${RUN_SCRIPT}" status
    ;;
  rollback)
    ssh_cmd "
      set -e
      [ -f '${SNAP_DIR}/LATEST' ]
      . '${SNAP_DIR}/LATEST'
      [ -n \"\${SNAPSHOT_TS:-}\" ]
      cp -f '${SNAP_DIR}/dpu-dualport-l2.'\"\$SNAPSHOT_TS\" '${DPU_DIR}/core/dpu-dualport-l2'
      if [ -f '${SNAP_DIR}/rules.json.'\"\$SNAPSHOT_TS\" ]; then
        cp -f '${SNAP_DIR}/rules.json.'\"\$SNAPSHOT_TS\" '${DPU_DIR}/configs/rules.json'
      fi
    "
    DPU_HOST="${DPU_HOST}" DPU_USER="${DPU_USER}" DPU_PASS="${DPU_PASS}" DPU_DIR="${DPU_DIR}" SUDO_PASS="${SUDO_PASS}" APP_MODE=poll EVENT_STRICT=0 "${RUN_SCRIPT}" stop
    DPU_HOST="${DPU_HOST}" DPU_USER="${DPU_USER}" DPU_PASS="${DPU_PASS}" DPU_DIR="${DPU_DIR}" SUDO_PASS="${SUDO_PASS}" APP_MODE=poll EVENT_STRICT=0 "${RUN_SCRIPT}" start
    DPU_HOST="${DPU_HOST}" DPU_USER="${DPU_USER}" DPU_PASS="${DPU_PASS}" DPU_DIR="${DPU_DIR}" "${RUN_SCRIPT}" status
    ;;
  status)
    DPU_HOST="${DPU_HOST}" DPU_USER="${DPU_USER}" DPU_PASS="${DPU_PASS}" DPU_DIR="${DPU_DIR}" "${RUN_SCRIPT}" status
    ssh_cmd "
      set -e
      [ -f '${DPU_DIR}/logs/dpu-dualport-l2.log' ] && tail -n 80 '${DPU_DIR}/logs/dpu-dualport-l2.log' | egrep '\\[start\\]|\\[event\\]|\\[stat\\]|fallback|failed' || true
    "
    ;;
  *)
    echo "usage: $0 {snapshot|start-event|start-poll|rollback|status}" >&2
    exit 2
    ;;
esac
