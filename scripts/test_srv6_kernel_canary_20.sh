#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/zyren/ospf-star-dpdk20"
LAB="${ROOT}/scripts/lab_er_vlan_subif.sh"
LOG_DIR="${ROOT}/logs"
TS="$(date +%Y%m%d_%H%M%S)"
LOG="${LOG_DIR}/test_srv6_kernel_canary_20_${TS}.log"

LAB_ID="${LAB_ID:-erv20}"
LAB_NODES="${LAB_NODES:-20}"
STATE_DIR="/tmp/${LAB_ID}_lab"
PLAN_DIR="${STATE_DIR}/plan"
SKIP_UP="${SKIP_UP:-1}"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

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

pick_triplet() {
  python3 - "$PLAN_DIR" "$LAB_NODES" <<'PY'
import os, sys
from collections import defaultdict
plan = sys.argv[1]
n = int(sys.argv[2])
adj = defaultdict(dict)
for node in range(1, n + 1):
    p = os.path.join(plan, f'ifs_{node}.txt')
    if not os.path.exists(p):
        continue
    with open(p, 'r', encoding='utf-8') as f:
        for line in f:
            t = line.strip().split()
            if len(t) >= 2:
                vid = int(t[0])
                peer = int(t[1])
                adj[node][peer] = vid

for src in range(1, n + 1):
    peers = sorted(adj[src].keys())
    for i in range(len(peers)):
        for j in range(i + 1, len(peers)):
            dst = peers[i]
            mid = peers[j]
            if dst in adj[mid]:  # triangle: src-dst, src-mid, mid-dst
                print(src, dst, mid, adj[src][dst], adj[src][mid], adj[mid][dst])
                raise SystemExit(0)
raise SystemExit('no suitable triangle triplet found')
PY
}

cap_count() {
  local c="$1" ifn="$2" pattern="$3"
  docker exec "$c" sh -lc "timeout 8 tcpdump -ni $ifn -c 20 '$pattern' > /tmp/srv6_cap.log 2>&1 &"
}

cleanup() {
  set +e
  if [[ -n "${SRC_C:-}" && -n "${DST_EP:-}" && -n "${SRC_DST_NH:-}" && -n "${SRC_IF_DST:-}" ]]; then
    docker exec "$SRC_C" ip -6 route replace "$DST_EP/128" via "$SRC_DST_NH" dev "$SRC_IF_DST" >/dev/null 2>&1 || true
  fi
  if [[ -n "${SRC_C:-}" && -n "${DST_EP:-}" ]]; then
    docker exec "$SRC_C" ip -6 route del "$DST_EP/128" >/dev/null 2>&1 || true
  fi
  if [[ -n "${MID_C:-}" && -n "${MID_SID:-}" ]]; then
    docker exec "$MID_C" ip -6 route del "$MID_SID/128" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_root
log "=== srv6 kernel canary start ==="
if [[ "$SKIP_UP" != "1" ]]; then
  LAB_ID="$LAB_ID" LAB_NODES="$LAB_NODES" "$LAB" up
fi
wait_check_ok 240

read -r SRC DST MID VID_DST VID_MID VID_MD <<<"$(pick_triplet)"
SRC_C="${LAB_ID}_r_${SRC}"
DST_C="${LAB_ID}_r_${DST}"
MID_C="${LAB_ID}_r_${MID}"
SRC_IF_DST="veth_0.${VID_DST}"
DST_IF_SRC="veth_0.${VID_DST}"
SRC_IF_MID="veth_0.${VID_MID}"
MID_IF_SRC="veth_0.${VID_MID}"
MID_IF_DST="veth_0.${VID_MD}"
DST_IF_MID="veth_0.${VID_MD}"

# IPv6 plan
SRC_DST_SRC_IP="fd00:${VID_DST}::1"
SRC_DST_DST_IP="fd00:${VID_DST}::2"
SRC_MID_SRC_IP="fd00:${VID_MID}::1"
SRC_MID_MID_IP="fd00:${VID_MID}::2"
DST_MID_DST_IP="fd00:${VID_MD}::2"
DST_MID_MID_IP="fd00:${VID_MD}::1"
DST_EP="fd00:255::${DST}"
MID_SID="fd00:face::${MID}"
SRC_DST_NH="$SRC_DST_DST_IP"

log "selected src=$SRC dst=$DST mid=$MID vid_dst=$VID_DST vid_mid=$VID_MID vid_md=$VID_MD"
log "dst_ep=$DST_EP mid_sid=$MID_SID"

# Enable IPv6 + SRv6 kernel knobs
for c in "$SRC_C" "$DST_C" "$MID_C"; do
  docker exec "$c" sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
  docker exec "$c" sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
  docker exec "$c" sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
  docker exec "$c" sysctl -w net.ipv6.conf.all.accept_source_route=1 >/dev/null
  docker exec "$c" sysctl -w net.ipv6.conf.default.accept_source_route=1 >/dev/null
  docker exec "$c" sysctl -w net.ipv6.conf.all.seg6_enabled=1 >/dev/null
  docker exec "$c" sysctl -w net.ipv6.conf.default.seg6_enabled=1 >/dev/null
  docker exec "$c" sysctl -w net.ipv6.conf.lo.seg6_enabled=1 >/dev/null
  docker exec "$c" sysctl -w net.ipv6.conf.veth_0.seg6_enabled=1 >/dev/null || true
done

# For VLAN subinterfaces with dot in name, set seg6 via /proc directly.
docker exec "$SRC_C" sh -lc "echo 1 > /proc/sys/net/ipv6/conf/${SRC_IF_MID}/seg6_enabled" || true
docker exec "$MID_C" sh -lc "echo 1 > /proc/sys/net/ipv6/conf/${MID_IF_SRC}/seg6_enabled" || true
docker exec "$MID_C" sh -lc "echo 1 > /proc/sys/net/ipv6/conf/${MID_IF_DST}/seg6_enabled" || true
docker exec "$DST_C" sh -lc "echo 1 > /proc/sys/net/ipv6/conf/${DST_IF_MID}/seg6_enabled" || true
docker exec "$DST_C" sh -lc "echo 1 > /proc/sys/net/ipv6/conf/${DST_IF_SRC}/seg6_enabled" || true

# Addressing
for cmd in \
  "docker exec $SRC_C ip -6 addr replace ${SRC_DST_SRC_IP}/64 dev $SRC_IF_DST" \
  "docker exec $DST_C ip -6 addr replace ${SRC_DST_DST_IP}/64 dev $DST_IF_SRC" \
  "docker exec $SRC_C ip -6 addr replace ${SRC_MID_SRC_IP}/64 dev $SRC_IF_MID" \
  "docker exec $MID_C ip -6 addr replace ${SRC_MID_MID_IP}/64 dev $MID_IF_SRC" \
  "docker exec $MID_C ip -6 addr replace ${DST_MID_MID_IP}/64 dev $MID_IF_DST" \
  "docker exec $DST_C ip -6 addr replace ${DST_MID_DST_IP}/64 dev $DST_IF_MID" \
  "docker exec $DST_C ip -6 addr replace ${DST_EP}/128 dev lo"; do
  eval "$cmd"
done

# Baseline route: direct src->dst

docker exec "$SRC_C" ip -6 route replace "$DST_EP/128" via "$SRC_DST_NH" dev "$SRC_IF_DST"
docker exec "$SRC_C" ip -6 route replace "$MID_SID/128" via "$SRC_MID_MID_IP" dev "$SRC_IF_MID"
docker exec "$MID_C" ip -6 route replace "$DST_EP/128" via "$DST_MID_DST_IP" dev "$MID_IF_DST"

log "[baseline] direct IPv6 ping should bypass mid"
cap_count "$MID_C" "$MID_IF_SRC" "icmp6 and host $DST_EP"
sleep 1
docker exec "$SRC_C" ping -6 -I "$SRC_DST_SRC_IP" -c 5 -W 1 "$DST_EP" | tee -a "$LOG"
docker exec "$MID_C" sh -lc "sleep 9; c=\$(grep -c 'ICMP6' /tmp/srv6_cap.log || true); echo baseline_mid_icmp6_count=\$c" | tee -a "$LOG"

log "[srv6] install kernel SRv6 policy: src encap -> mid End.DX6 -> dst"
docker exec "$MID_C" ip -6 route replace local "$MID_SID/128" encap seg6local action End.DX6 nh6 "$DST_MID_DST_IP" dev "$MID_IF_DST"
docker exec "$SRC_C" ip -6 route replace "$DST_EP/128" encap seg6 mode encap segs "$MID_SID" via "$SRC_MID_MID_IP" dev "$SRC_IF_MID"

cap_count "$MID_C" "$MID_IF_SRC" "ip6"
docker exec "$MID_C" sh -lc "timeout 8 tcpdump -ni $MID_IF_DST -c 20 'ip6' > /tmp/srv6_cap_mid_dst.log 2>&1 &"
docker exec "$DST_C" sh -lc "timeout 8 tcpdump -ni $DST_IF_MID -c 20 'ip6' > /tmp/srv6_cap_dst_in.log 2>&1 &"
sleep 1
docker exec "$SRC_C" ping -6 -I "$SRC_DST_SRC_IP" -c 5 -W 1 "$DST_EP" | tee -a "$LOG" || true
docker exec "$MID_C" sh -lc "sleep 9; c=\$(grep -c 'IP6' /tmp/srv6_cap.log || true); echo srv6_mid_ip6_count=\$c; cat /tmp/srv6_cap.log" | tee -a "$LOG"
docker exec "$MID_C" sh -lc "c=\$(grep -c 'IP6' /tmp/srv6_cap_mid_dst.log || true); echo srv6_mid_dst_ip6_count=\$c; cat /tmp/srv6_cap_mid_dst.log" | tee -a "$LOG"
docker exec "$DST_C" sh -lc "c=\$(grep -c 'IP6' /tmp/srv6_cap_dst_in.log || true); echo srv6_dst_in_ip6_count=\$c; cat /tmp/srv6_cap_dst_in.log" | tee -a "$LOG"

# Verify SRv6 route exists
log "[verify] source + mid route entries"
docker exec "$SRC_C" ip -6 route show "$DST_EP/128" | tee -a "$LOG"
docker exec "$MID_C" ip -6 route show "$MID_SID/128" | tee -a "$LOG"

log "=== srv6 kernel canary done ==="
log "log_file=$LOG"
