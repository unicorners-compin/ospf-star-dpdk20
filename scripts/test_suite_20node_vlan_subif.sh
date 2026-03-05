#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/zyren/ospf-star-dpdk20"
LAB="${ROOT}/scripts/lab_er_vlan_subif.sh"
LOG_DIR="${ROOT}/logs"
TS="$(date +%Y%m%d_%H%M%S)"
LOG="${LOG_DIR}/test_suite_20node_vlan_subif_${TS}.log"

LAB_ID="${LAB_ID:-erv20}"
LAB_NODES="${LAB_NODES:-20}"
ER_P="${ER_P:-0.18}"
ER_SEED="${ER_SEED:-20260305}"
STATE_DIR="/tmp/${LAB_ID}_lab"
TOPO_JSON="${STATE_DIR}/topo_er.json"
PLAN_DIR="${STATE_DIR}/plan"

mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG"
}

run() {
  log "CMD: $*"
  eval "$*" 2>&1 | tee -a "$LOG"
}

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

check_routes_ok() {
  local out="$1"
  grep -q 'miss_nodes=0' <<<"$out" && grep -q 'miss_total=0' <<<"$out"
}

wait_check_ok() {
  local timeout_s="${1:-180}"
  local start now out
  start="$(date +%s)"
  while true; do
    out="$(LAB_ID="$LAB_ID" LAB_NODES="$LAB_NODES" "$LAB" check 2>&1 || true)"
    echo "$out" | tee -a "$LOG"
    if check_ok "$out"; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_s )); then
      log "ASSERT FAIL: check not converged within ${timeout_s}s"
      return 1
    fi
    sleep 5
  done
}

wait_routes_ok() {
  local timeout_s="${1:-180}"
  local start now out
  start="$(date +%s)"
  while true; do
    out="$(LAB_ID="$LAB_ID" LAB_NODES="$LAB_NODES" "$LAB" check 2>&1 || true)"
    echo "$out" | tee -a "$LOG"
    if check_routes_ok "$out"; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_s )); then
      log "ASSERT FAIL: routes not converged within ${timeout_s}s"
      return 1
    fi
    sleep 5
  done
}

pick_non_bridge_edge() {
  python3 - "$TOPO_JSON" <<'PY'
import json, sys
from collections import defaultdict

j = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
edges = [tuple(sorted((int(u), int(v)))) for u, v in j.get('edges', [])]
edges = sorted(set(edges))
if not edges:
    raise SystemExit('no edges')

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
    if (idx - 1) not in bridges:
        vid = 100 + idx
        print(f"{u} {v} {vid}")
        raise SystemExit(0)

# fallback: first edge
u, v = edges[0]
print(f"{u} {v} {101}")
PY
}

must_ping_ok() {
  local src="$1" dst_ip="$2"
  local c="${LAB_ID}_r_${src}"
  local out
  out="$(docker exec "$c" ping -c 3 -W 1 "$dst_ip" 2>&1 || true)"
  echo "$out" | tee -a "$LOG"
  echo "$out" | grep -q ' 0% packet loss' || {
    log "ASSERT FAIL: ping ${c} -> ${dst_ip} not 0%"
    return 1
  }
}

sample_ping_matrix() {
  local nodes=(1 5 10 15 20)
  local s d ip
  for s in "${nodes[@]}"; do
    for d in "${nodes[@]}"; do
      [[ "$s" == "$d" ]] && continue
      ip="10.255.30.${d}"
      must_ping_ok "$s" "$ip"
    done
  done
}

neighbor_full_count() {
  local node="$1"
  docker exec "${LAB_ID}_r_${node}" vtysh -c 'show ip ospf neighbor' 2>/dev/null | awk 'NR>1 && /Full\//{c++} END{print c+0}'
}

require_root

log "=== start 20-node vlan-subif full suite ==="
run "LAB_ID=$LAB_ID LAB_NODES=$LAB_NODES ER_P=$ER_P ER_SEED=$ER_SEED $LAB up"
run "LAB_ID=$LAB_ID LAB_NODES=$LAB_NODES $LAB show-topo"
sleep 8

log "[BASELINE] wait OSPF convergence + full route check"
wait_check_ok 240

log "[BASELINE] sample ping matrix"
sample_ping_matrix

read -r U V VID <<<"$(pick_non_bridge_edge)"
log "[CASE LINK CUT] picked non-bridge edge u=$U v=$V vlan=$VID"

BASE_U="$(cat "$PLAN_DIR/degree_${U}.txt")"
BASE_V="$(cat "$PLAN_DIR/degree_${V}.txt")"
log "baseline_degree u=$U:$BASE_U v=$V:$BASE_V"

run "docker exec ${LAB_ID}_r_${U} ip link set veth_0.${VID} down"
run "docker exec ${LAB_ID}_r_${V} ip link set veth_0.${VID} down"
sleep 25

CUT_U="$(neighbor_full_count "$U")"
CUT_V="$(neighbor_full_count "$V")"
log "after_cut_full_neighbors u=$U:$CUT_U v=$V:$CUT_V"

if [[ "$CUT_U" -gt "$BASE_U" || "$CUT_V" -gt "$BASE_V" ]]; then
  log "ASSERT FAIL: invalid neighbor counts after cut"
  exit 1
fi

log "[CASE LINK CUT] verify network still converged (non-bridge edge expected)"
wait_routes_ok 240

run "docker exec ${LAB_ID}_r_${U} ip link set veth_0.${VID} up"
run "docker exec ${LAB_ID}_r_${V} ip link set veth_0.${VID} up"
sleep 20

log "[CASE LINK RECOVER] verify reconvergence"
wait_check_ok 240

log "[CASE LINK RECOVER] sample ping matrix"
sample_ping_matrix

log "=== PASS: 20-node full suite completed ==="
log "log_file=$LOG"
