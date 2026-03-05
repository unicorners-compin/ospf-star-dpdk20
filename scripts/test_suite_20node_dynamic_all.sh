#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/zyren/ospf-star-dpdk20"
LAB="${ROOT}/scripts/lab_er_vlan_subif.sh"
LOG_DIR="${ROOT}/logs"
TS="$(date +%Y%m%d_%H%M%S)"
LOG="${LOG_DIR}/test_suite_20node_dynamic_all_${TS}.log"

LAB_ID="${LAB_ID:-erv20}"
LAB_NODES="${LAB_NODES:-20}"
ER_P="${ER_P:-0.18}"
ER_SEED="${ER_SEED:-20260305}"
SKIP_UP="${SKIP_UP:-0}"
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

u, v = edges[0]
print(f"{u} {v} {101}")
PY
}

get_link_ip() {
  local node="$1" vid="$2"
  awk -v vid="$vid" '$1==vid{print $3; exit}' "${PLAN_DIR}/ifs_${node}.txt"
}

must_ping_ok_link() {
  local node="$1" iface="$2" dst="$3"
  local c="${LAB_ID}_r_${node}"
  local out
  out="$(docker exec "$c" ping -I "$iface" -c 4 -W 1 "$dst" 2>&1 || true)"
  echo "$out" | tee -a "$LOG"
  echo "$out" | grep -q ' 0% packet loss' || { log "ASSERT FAIL: ping ${c}:${iface} -> ${dst} not 0%"; return 1; }
}

must_ping_fail_link() {
  local node="$1" iface="$2" dst="$3"
  local c="${LAB_ID}_r_${node}"
  local out
  out="$(docker exec "$c" ping -I "$iface" -c 4 -W 1 "$dst" 2>&1 || true)"
  echo "$out" | tee -a "$LOG"
  echo "$out" | grep -Eq '100% packet loss|Network is unreachable|bind: Cannot assign requested address|connect: Invalid argument' || {
    log "ASSERT FAIL: expected ping failure ${c}:${iface} -> ${dst}"
    return 1
  }
}

iperf_mbps() {
  local c_src="$1" src_ip="$2" dst_ip="$3" port="$4"
  docker exec "$c_src" sh -lc "iperf3 -c $dst_ip -B $src_ip -p $port -t 8 -f m" \
    | tee -a "$LOG" \
    | awk '/receiver/{v=$(NF-2)} END{print v+0}'
}

iperf_mbps_retry() {
  local c_src="$1" src_ip="$2" dst_ip="$3" port="$4"
  local out="0" i
  for i in 1 2 3; do
    out="$(iperf_mbps "$c_src" "$src_ip" "$dst_ip" "$port" || true)"
    if awk -v v="$out" 'BEGIN{exit !(v>0)}'; then
      echo "$out"
      return 0
    fi
    sleep 1
  done
  echo "$out"
  return 1
}

clear_iface_impair() {
  local node iface c
  node="$1"
  iface="$2"
  c="${LAB_ID}_r_${node}"
  docker exec "$c" tc qdisc del dev "$iface" root 2>/dev/null || true
}

start_iperf_server() {
  local c="$1" bind_ip="$2" port="$3"
  docker exec "$c" sh -lc "pid=\$(ss -lntp \"sport = :$port\" 2>/dev/null | sed -n 's/.*pid=\\([0-9]\\+\\).*/\\1/p' | head -n1); [ -n \"\$pid\" ] && kill \"\$pid\" >/dev/null 2>&1 || true; iperf3 -s -D -B $bind_ip -p $port"
  sleep 1
}

stop_iperf_server() {
  local c="$1" port="$2"
  docker exec "$c" sh -lc "pid=\$(ss -lntp \"sport = :$port\" 2>/dev/null | sed -n 's/.*pid=\\([0-9]\\+\\).*/\\1/p' | head -n1); [ -n \"\$pid\" ] && kill \"\$pid\" >/dev/null 2>&1 || true"
}

cleanup() {
  set +e
  if [[ -n "${U:-}" && -n "${IF_U:-}" ]]; then
    docker exec "${LAB_ID}_r_${U}" ip link set "$IF_U" up >/dev/null 2>&1 || true
    docker exec "${LAB_ID}_r_${U}" tc qdisc del dev "$IF_U" root >/dev/null 2>&1 || true
  fi
  if [[ -n "${V:-}" && -n "${IF_V:-}" ]]; then
    docker exec "${LAB_ID}_r_${V}" ip link set "$IF_V" up >/dev/null 2>&1 || true
    docker exec "${LAB_ID}_r_${V}" tc qdisc del dev "$IF_V" root >/dev/null 2>&1 || true
  fi
  wait_check_ok 180 >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_root

log "=== start 20-node dynamic all-in-one suite ==="
if [[ "$SKIP_UP" == "1" ]]; then
  log "skip_up=1 use existing lab"
else
  run "LAB_ID=$LAB_ID LAB_NODES=$LAB_NODES ER_P=$ER_P ER_SEED=$ER_SEED $LAB up"
fi
wait_check_ok 240

read -r U V VID <<<"$(pick_non_bridge_edge)"
IF_U="veth_0.${VID}"
IF_V="veth_0.${VID}"
U_IP="$(get_link_ip "$U" "$VID")"
V_IP="$(get_link_ip "$V" "$VID")"
CU="${LAB_ID}_r_${U}"
CV="${LAB_ID}_r_${V}"

if [[ -z "$U_IP" || -z "$V_IP" ]]; then
  log "ASSERT FAIL: cannot resolve link ip for u=$U v=$V vid=$VID"
  exit 1
fi

log "edge_selected u=$U v=$V vid=$VID u_ip=$U_IP v_ip=$V_IP"

log "[BASELINE] direct unicast ping on selected link"
must_ping_ok_link "$U" "$IF_U" "$V_IP"

log "[CASE1 Unicast+QoS] baseline iperf"
run "start_iperf_server $CV $V_IP 5201"
BASE_MBPS="$(iperf_mbps_retry "$CU" "$U_IP" "$V_IP" 5201)"
log "baseline_iperf_mbps=$BASE_MBPS"
run "stop_iperf_server $CV 5201"

log "[CASE1 Unicast+QoS] apply tc tbf 10mbit on $CU:$IF_U"
run "docker exec $CU tc qdisc replace dev $IF_U root tbf rate 10mbit burst 64kb latency 100ms"
run "start_iperf_server $CV $V_IP 5202"
QOS_MBPS="$(iperf_mbps_retry "$CU" "$U_IP" "$V_IP" 5202)"
log "qos_iperf_mbps=$QOS_MBPS"
awk -v v="$QOS_MBPS" 'BEGIN{exit !(v<=15.0)}' || { log "ASSERT FAIL: qos not effective mbps=$QOS_MBPS"; exit 1; }
run "stop_iperf_server $CV 5202"
clear_iface_impair "$U" "$IF_U"

log "[CASE2 Delay] apply 120ms each direction"
run "docker exec $CU tc qdisc replace dev $IF_U root netem delay 120ms"
run "docker exec $CV tc qdisc replace dev $IF_V root netem delay 120ms"
PING_DELAY_OUT="$(docker exec "$CU" ping -I "$IF_U" -c 5 -W 2 "$V_IP" 2>&1 || true)"
echo "$PING_DELAY_OUT" | tee -a "$LOG"
DELAY_AVG="$(echo "$PING_DELAY_OUT" | awk -F'/' '/^rtt/{print $5+0}')"
log "delay_avg_ms=$DELAY_AVG"
awk -v d="$DELAY_AVG" 'BEGIN{exit !(d>=180)}' || { log "ASSERT FAIL: delay too low avg_ms=$DELAY_AVG"; exit 1; }
clear_iface_impair "$U" "$IF_U"
clear_iface_impair "$V" "$IF_V"

log "[CASE3 Cut] link down/up"
run "docker exec $CU ip link set $IF_U down"
run "docker exec $CV ip link set $IF_V down"
sleep 3
must_ping_fail_link "$U" "$IF_U" "$V_IP"
run "docker exec $CU ip link set $IF_U up"
run "docker exec $CV ip link set $IF_V up"
sleep 20
must_ping_ok_link "$U" "$IF_U" "$V_IP"
wait_check_ok 240

log "[CASE4 Broadcast] ARP broadcast capture on peer"
run "docker exec $CV sh -lc 'timeout 10 tcpdump -ni $IF_V -c 1 \"arp and ether dst ff:ff:ff:ff:ff:ff\" > /tmp/bcast_cap.log 2>&1 &'"
sleep 1
run "docker exec $CU sh -lc 'ip neigh del $V_IP dev $IF_U 2>/dev/null || true; ping -I $IF_U -c 1 -W 1 $V_IP >/dev/null 2>&1 || true'"
run "docker exec $CV sh -lc 'sleep 2; cat /tmp/bcast_cap.log'"
run "docker exec $CV sh -lc 'grep -q \"ARP\" /tmp/bcast_cap.log'"

log "[CASE5 Multicast] OSPF hello multicast capture on peer"
run "docker exec $CV sh -lc 'timeout 12 tcpdump -ni $IF_V -c 1 \"ip proto 89 and dst 224.0.0.5\" > /tmp/mcast_cap.log 2>&1 &'"
run "docker exec $CV sh -lc 'sleep 7; cat /tmp/mcast_cap.log'"
run "docker exec $CV sh -lc 'grep -q \"OSPF\" /tmp/mcast_cap.log || grep -q \"proto OSPF\" /tmp/mcast_cap.log || grep -q \"224.0.0.5\" /tmp/mcast_cap.log'"

log "[FINAL] full ospf check"
wait_check_ok 240

log "=== PASS: dynamic suite completed (qos/cut/delay/unicast/broadcast/multicast) ==="
log "log_file=$LOG"
