#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/zyren/ospf-star-dpdk20"
LAB="${ROOT}/scripts/lab_er_vlan_subif.sh"
LOG_DIR="${ROOT}/logs"
TS="$(date +%Y%m%d_%H%M%S)"
LOG="${LOG_DIR}/benchmark_dynamic_topo_20_${TS}.log"
CSV="${LOG_DIR}/benchmark_dynamic_topo_20_${TS}.csv"

LAB_ID="${LAB_ID:-erv20}"
LAB_NODES="${LAB_NODES:-20}"
STATE_DIR="/tmp/${LAB_ID}_lab"
TOPO_JSON="${STATE_DIR}/topo_er.json"
PLAN_DIR="${STATE_DIR}/plan"
SKIP_UP="${SKIP_UP:-1}"
ROUNDS="${ROUNDS:-10}"
HOLD_SEC="${HOLD_SEC:-5}"
ROUND_INTERVAL_SEC="${ROUND_INTERVAL_SEC:-10}"

mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG"
}

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
    if check_ok "$out"; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_s )); then
      log "ASSERT FAIL: full check not converged in ${timeout_s}s"
      return 1
    fi
    sleep 2
  done
}

wait_routes_ok_ms() {
  local timeout_s="${1:-120}"
  local t0 now out
  t0="$(now_ms)"
  while true; do
    out="$(LAB_ID="$LAB_ID" LAB_NODES="$LAB_NODES" "$LAB" check 2>&1 || true)"
    if check_routes_ok "$out"; then
      now="$(now_ms)"
      echo $((now - t0))
      return 0
    fi
    now="$(now_ms)"
    if (( now - t0 >= timeout_s * 1000 )); then
      echo -1
      return 1
    fi
    sleep 1
  done
}

pick_non_bridge_edges() {
  python3 - "$TOPO_JSON" <<'PY'
import json, sys
from collections import defaultdict

j = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
edges = [tuple(sorted((int(u), int(v)))) for u, v in j.get('edges', [])]
edges = sorted(set(edges))
adj = defaultdict(list)
for i, (u, v) in enumerate(edges):
    adj[u].append((v, i))
    adj[v].append((u, i))
if not edges:
    raise SystemExit('no edges')
n = max(max(u, v) for u, v in edges)
tin = [-1]*(n+1)
low = [-1]*(n+1)
vis = [False]*(n+1)
bridges = set()
timer = 0

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

for v in range(1, n+1):
    if v in adj and not vis[v]:
        dfs(v)

for idx, (u, v) in enumerate(edges, start=1):
    if (idx-1) not in bridges:
        vid = 100 + idx
        print(f"{u} {v} {vid}")
PY
}

link_ip() {
  local node="$1" vid="$2"
  awk -v vid="$vid" '$1==vid{print $3; exit}' "${PLAN_DIR}/ifs_${node}.txt"
}

ping_ok() {
  local c="$1" iface="$2" dst="$3"
  docker exec "$c" ping -I "$iface" -c 1 -W 1 "$dst" >/dev/null 2>&1
}

quantiles() {
  local col="$1"
  python3 - "$CSV" "$col" <<'PY'
import csv, sys, math
p = sys.argv[1]
col = int(sys.argv[2])
vals = []
with open(p, 'r', encoding='utf-8') as f:
    r = csv.reader(f)
    next(r, None)
    for row in r:
        try:
            v = float(row[col])
        except Exception:
            continue
        if v >= 0:
            vals.append(v)
if not vals:
    print('na,na,na')
    raise SystemExit(0)
vals.sort()
def q(x):
    if len(vals) == 1:
        return vals[0]
    pos = x * (len(vals)-1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return vals[lo]
    return vals[lo] + (vals[hi]-vals[lo])*(pos-lo)
print(f"{q(0.50):.1f},{q(0.95):.1f},{q(0.99):.1f}")
PY
}

require_root

log "=== dynamic topo benchmark start ==="
if [[ "$SKIP_UP" == "1" ]]; then
  log "skip_up=1 use existing lab"
else
  LAB_ID="$LAB_ID" LAB_NODES="$LAB_NODES" "$LAB" up
fi
wait_check_ok 240

mapfile -t EDGES < <(pick_non_bridge_edges)
if [[ "${#EDGES[@]}" -eq 0 ]]; then
  log "ASSERT FAIL: no non-bridge edges"
  exit 1
fi

printf "round,u,v,vid,t_apply_down_ms,t_routes_ok_down_ms,t_recover_up_ms,t_full_converge_ms,loss_window_ms\n" > "$CSV"

for r in $(seq 1 "$ROUNDS"); do
  idx=$(( (r - 1) % ${#EDGES[@]} ))
  read -r U V VID <<<"${EDGES[$idx]}"
  CU="${LAB_ID}_r_${U}"
  CV="${LAB_ID}_r_${V}"
  IF_U="veth_0.${VID}"
  IF_V="veth_0.${VID}"
  V_IP="$(link_ip "$V" "$VID")"

  log "[round=$r] edge u=$U v=$V vid=$VID"
  docker exec "$CU" ip link set "$IF_U" up >/dev/null 2>&1 || true
  docker exec "$CV" ip link set "$IF_V" up >/dev/null 2>&1 || true

  if ! ping_ok "$CU" "$IF_U" "$V_IP"; then
    log "[round=$r] baseline ping not ok, skip"
    continue
  fi

  t0="$(now_ms)"
  docker exec "$CU" ip link set "$IF_U" down
  docker exec "$CV" ip link set "$IF_V" down

  t_apply=-1
  for _ in $(seq 1 20); do
    if ! ping_ok "$CU" "$IF_U" "$V_IP"; then
      t_apply=$(( $(now_ms) - t0 ))
      break
    fi
    sleep 0.2
  done

  t_routes="$(wait_routes_ok_ms 60 || true)"

  sleep "$HOLD_SEC"
  t_up0="$(now_ms)"
  docker exec "$CU" ip link set "$IF_U" up
  docker exec "$CV" ip link set "$IF_V" up

  t_recover=-1
  for _ in $(seq 1 60); do
    if ping_ok "$CU" "$IF_U" "$V_IP"; then
      t_recover=$(( $(now_ms) - t_up0 ))
      break
    fi
    sleep 0.5
  done

  tf0="$(now_ms)"
  if wait_check_ok 120; then
    t_full=$(( $(now_ms) - tf0 ))
  else
    t_full=-1
  fi

  if (( t_apply >= 0 && t_recover >= 0 )); then
    loss_win=$(( (t_up0 - t0) + t_recover ))
  else
    loss_win=-1
  fi

  echo "$r,$U,$V,$VID,$t_apply,$t_routes,$t_recover,$t_full,$loss_win" >> "$CSV"
  log "[round=$r] t_apply_down_ms=$t_apply t_routes_ok_down_ms=$t_routes t_recover_up_ms=$t_recover t_full_converge_ms=$t_full loss_window_ms=$loss_win"

  sleep "$ROUND_INTERVAL_SEC"
done

read p50a p95a p99a <<<"$(quantiles 4 | tr ',' ' ')"
read p50b p95b p99b <<<"$(quantiles 5 | tr ',' ' ')"
read p50c p95c p99c <<<"$(quantiles 6 | tr ',' ' ')"
read p50d p95d p99d <<<"$(quantiles 7 | tr ',' ' ')"
read p50e p95e p99e <<<"$(quantiles 8 | tr ',' ' ')"

log "summary.t_apply_down_ms p50=$p50a p95=$p95a p99=$p99a"
log "summary.t_routes_ok_down_ms p50=$p50b p95=$p95b p99=$p99b"
log "summary.t_recover_up_ms p50=$p50c p95=$p95c p99=$p99c"
log "summary.t_full_converge_ms p50=$p50d p95=$p95d p99=$p99d"
log "summary.loss_window_ms p50=$p50e p95=$p95e p99=$p99e"
log "csv_file=$CSV"
log "=== dynamic topo benchmark done ==="
