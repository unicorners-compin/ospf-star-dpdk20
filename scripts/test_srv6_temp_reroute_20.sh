#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/zyren/ospf-star-dpdk20"
LAB="${ROOT}/scripts/lab_er_vlan_subif.sh"
LOG_DIR="${ROOT}/logs"
TS="$(date +%Y%m%d_%H%M%S)"
LOG="${LOG_DIR}/test_srv6_temp_reroute_20_${TS}.log"

LAB_ID="${LAB_ID:-erv20}"
LAB_NODES="${LAB_NODES:-20}"
STATE_DIR="/tmp/${LAB_ID}_lab"
TOPO_JSON="${STATE_DIR}/topo_er.json"
PLAN_DIR="${STATE_DIR}/plan"
SKIP_UP="${SKIP_UP:-1}"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
now_ms() { date +%s%3N; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "run with sudo -n" >&2
    exit 2
  fi
}

check_ok() {
  local out="$1"
  grep -q 'bad_neighbor_nodes=0' <<<"$out" && grep -q 'miss_nodes=0' <<<"$out" && grep -q 'miss_total=0' <<<"$out"
}

wait_check_ok() {
  local timeout_s="${1:-180}" start now out
  start="$(date +%s)"
  while true; do
    out="$(LAB_ID="$LAB_ID" LAB_NODES="$LAB_NODES" "$LAB" check 2>&1 || true)"
    if check_ok "$out"; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_s )); then
      log "ASSERT FAIL: OSPF not converged in ${timeout_s}s"
      return 1
    fi
    sleep 2
  done
}

pick_edge() {
  python3 - "$TOPO_JSON" <<'PY'
import json, sys
from collections import defaultdict
j = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
edges = [tuple(sorted((int(u), int(v)))) for u, v in j.get('edges', [])]
edges = sorted(set(edges))
deg = defaultdict(int)
for u, v in edges:
    deg[u] += 1
    deg[v] += 1

adj = defaultdict(list)
for i, (u, v) in enumerate(edges):
    adj[u].append((v, i))
    adj[v].append((u, i))

n = max(max(u, v) for u, v in edges)
tin = [-1] * (n + 1)
low = [-1] * (n + 1)
vis = [False] * (n + 1)
bridges = set()
timer = 0

sys.setrecursionlimit(1000000)

def dfs(v, pe=-1):
    global timer
    vis[v] = True
    tin[v] = low[v] = timer
    timer += 1
    for to, ei in adj[v]:
        if ei == pe:
            continue
        if vis[to]:
            low[v] = min(low[v], tin[to])
        else:
            dfs(to, ei)
            low[v] = min(low[v], low[to])
            if low[to] > tin[v]:
                bridges.add(ei)

for v in range(1, n + 1):
    if v in adj and not vis[v]:
        dfs(v)

for idx, (u, v) in enumerate(edges, start=1):
    # skip bridges; require both ends have alternate degree
    if (idx - 1) in bridges:
        continue
    if deg[u] >= 2 and deg[v] >= 2:
        print(f"{u} {v} {100+idx}")
        raise SystemExit(0)
raise SystemExit('no suitable non-bridge edge')
PY
}

flip_last_bit_ip() {
  local ip="$1"
  python3 - <<PY
ip = "$ip".strip().split('.')
ip[-1] = str(int(ip[-1]) ^ 1)
print('.'.join(ip))
PY
}

get_local_ip_by_vid() {
  local node="$1" vid="$2"
  awk -v vid="$vid" '$1==vid{print $3; exit}' "${PLAN_DIR}/ifs_${node}.txt"
}

pick_backup_for_source() {
  local src="$1" failed_vid="$2"
  awk -v bad="$failed_vid" '$1!=bad{print $1" "$3; exit}' "${PLAN_DIR}/ifs_${src}.txt"
}

ping_once() {
  local c="$1" dst="$2"
  docker exec "$c" ping -c 1 -W 1 "$dst" >/dev/null 2>&1
}

wait_ping_success_ms() {
  local c="$1" dst="$2" timeout_s="${3:-30}"
  local t0 now
  t0="$(now_ms)"
  while true; do
    if ping_once "$c" "$dst"; then
      now="$(now_ms)"
      echo $((now - t0))
      return 0
    fi
    now="$(now_ms)"
    if (( now - t0 >= timeout_s * 1000 )); then
      echo -1
      return 1
    fi
    sleep 0.2
  done
}

cleanup() {
  set +e
  if [[ -n "${SRC_C:-}" && -n "${DST_LO:-}" && -n "${BKP_NH:-}" && -n "${BKP_IF:-}" ]]; then
    docker exec "$SRC_C" ip route del "${DST_LO}/32" via "$BKP_NH" dev "$BKP_IF" >/dev/null 2>&1 || true
  fi
  if [[ -n "${SRC_C:-}" && -n "${SRC_IF_FAIL:-}" ]]; then
    docker exec "$SRC_C" ip link set "$SRC_IF_FAIL" up >/dev/null 2>&1 || true
  fi
  if [[ -n "${DST_C:-}" && -n "${DST_IF_FAIL:-}" ]]; then
    docker exec "$DST_C" ip link set "$DST_IF_FAIL" up >/dev/null 2>&1 || true
  fi
  wait_check_ok 180 >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_root
log "=== srv6-temp-reroute mock test start ==="
if [[ "$SKIP_UP" != "1" ]]; then
  LAB_ID="$LAB_ID" LAB_NODES="$LAB_NODES" "$LAB" up
fi
wait_check_ok 240

read -r SRC DST FAIL_VID <<<"$(pick_edge)"
SRC_C="${LAB_ID}_r_${SRC}"
DST_C="${LAB_ID}_r_${DST}"
SRC_IF_FAIL="veth_0.${FAIL_VID}"
DST_IF_FAIL="veth_0.${FAIL_VID}"
DST_LO="10.255.30.${DST}"

read -r BKP_VID BKP_LOCAL_IP <<<"$(pick_backup_for_source "$SRC" "$FAIL_VID")"
if [[ -z "${BKP_VID:-}" || -z "${BKP_LOCAL_IP:-}" ]]; then
  log "ASSERT FAIL: source node has no backup neighbor"
  exit 1
fi
BKP_IF="veth_0.${BKP_VID}"
BKP_NH="$(flip_last_bit_ip "$BKP_LOCAL_IP")"

log "selected src=$SRC dst=$DST fail_vid=$FAIL_VID dst_lo=$DST_LO backup_if=$BKP_IF backup_nh=$BKP_NH"

# Baseline: fail edge, no temporary policy
log "[baseline] fail edge without temporary reroute policy"
docker exec "$SRC_C" ip route del "${DST_LO}/32" via "$BKP_NH" dev "$BKP_IF" >/dev/null 2>&1 || true

docker exec "$SRC_C" ip link set "$SRC_IF_FAIL" down
docker exec "$DST_C" ip link set "$DST_IF_FAIL" down
BASE_RECOVER_MS="$(wait_ping_success_ms "$SRC_C" "$DST_LO" 60 || true)"
log "baseline_recover_ms=$BASE_RECOVER_MS"

docker exec "$SRC_C" ip link set "$SRC_IF_FAIL" up
docker exec "$DST_C" ip link set "$DST_IF_FAIL" up
wait_check_ok 240

# Temp policy: fail edge + immediate policy injection (mock SR policy)
log "[temp-policy] fail edge then inject temporary source override route"
docker exec "$SRC_C" ip route del "${DST_LO}/32" via "$BKP_NH" dev "$BKP_IF" >/dev/null 2>&1 || true

docker exec "$SRC_C" ip link set "$SRC_IF_FAIL" down
docker exec "$DST_C" ip link set "$DST_IF_FAIL" down

# emulate "upstream node notifies source" then source installs temporary path
EVENT_TS="$(date +%s)"
log "event_notify ts=${EVENT_TS} failed_edge=${SRC}-${DST}"
docker exec "$SRC_C" ip route replace "${DST_LO}/32" via "$BKP_NH" dev "$BKP_IF" metric 5

TEMP_RECOVER_MS="$(wait_ping_success_ms "$SRC_C" "$DST_LO" 60 || true)"
log "temp_policy_recover_ms=$TEMP_RECOVER_MS"

docker exec "$SRC_C" ip route del "${DST_LO}/32" via "$BKP_NH" dev "$BKP_IF" >/dev/null 2>&1 || true

docker exec "$SRC_C" ip link set "$SRC_IF_FAIL" up
docker exec "$DST_C" ip link set "$DST_IF_FAIL" up
wait_check_ok 240

python3 - <<PY | tee -a "$LOG"
b = float("${BASE_RECOVER_MS}")
t = float("${TEMP_RECOVER_MS}")
if b > 0 and t > 0:
    imp = (b - t) / b * 100.0
    print(f"improvement_pct={imp:.2f}")
else:
    print("improvement_pct=na")
PY

log "=== srv6-temp-reroute mock test done ==="
log "log_file=$LOG"
