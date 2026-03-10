#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
ROOT="/home/zyren/ospf-star-dpdk20"

LAB_ID="${LAB_ID:-star300lite}"
NODES="${LAB_NODES:-300}"
BR="${LAB_ID}_br"
PREFIX="${LAB_ID}_r"
STATE_DIR="/tmp/${LAB_ID}_lab"
IF_TAG="${IF_TAG:-s3l}"

IMG_NODE="${IMG_NODE:-ubuntu/sim-node-lite:v1}"
IMG_SIM="${IMG_SIM:-ubuntu/sim-node-lite:v1}"
SIM_C="${LAB_ID}_sim"

SIM_IN_H="${IF_TAG}_sinh"
SIM_IN_C="${IF_TAG}_sinc"
SIM_OUT_H="${IF_TAG}_south"
SIM_OUT_C="${IF_TAG}_soutc"
SIM_POLICY_IN_C="/opt/sim/policy.json"
SIM_PROG_IN_C="/opt/sim/l2_center_sim.py"
SIM_POLICY_GEN="${STATE_DIR}/sim_policy.star.json"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }

ip_octets() {
  local idx="$1"
  local n=$((idx - 1))
  local third=$((n / 254))
  local fourth=$((n % 254 + 1))
  echo "$third $fourth"
}

node_ip() {
  local t f
  read -r t f <<<"$(ip_octets "$1")"
  echo "10.20.${t}.${f}"
}

node_lo() {
  local t f
  read -r t f <<<"$(ip_octets "$1")"
  echo "10.255.${t}.${f}"
}

ensure_prereqs() {
  need docker
  need ovs-vsctl
  need ovs-ofctl
  need ip
  need python3
  mkdir -p "$STATE_DIR"
}

disable_host_offloads() {
  local dev="$1"
  ethtool -K "$dev" rx off tx off tso off gso off gro off lro off rxvlan off txvlan off >/dev/null 2>&1 || true
}

disable_container_offloads() {
  local c="$1"
  local dev="$2"
  docker exec "$c" sh -lc "ethtool -K $dev rx off tx off tso off gso off gro off lro off rxvlan off txvlan off >/dev/null 2>&1 || true"
}

render_neighbors() {
  local center=1
  for i in $(seq 1 "$NODES"); do
    : > "${STATE_DIR}/neighbors_${i}.txt"
  done
  for i in $(seq 2 "$NODES"); do
    echo "$i" >> "${STATE_DIR}/neighbors_${center}.txt"
    echo "$center" >> "${STATE_DIR}/neighbors_${i}.txt"
  done
  echo "[ok] star neighbors rendered center=${center} leaves=$((NODES-1))"
}

ensure_node() {
  local i="$1"
  local c="${PREFIX}_${i}"
  local vh="${IF_TAG}h_${i}"
  local vc="${IF_TAG}c_${i}"

  if ! docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    docker run -d --name "$c" --hostname "$c" --network none --privileged "$IMG_NODE" tail -f /dev/null >/dev/null
  else
    docker start "$c" >/dev/null || true
  fi

  ip link del "$vh" 2>/dev/null || true
  ip link add "$vh" type veth peer name "$vc"
  ip link set "$vh" up
  disable_host_offloads "$vh"
  ovs-vsctl --may-exist add-port "$BR" "$vh" -- set Interface "$vh" ofport_request="$i"

  local pid
  pid="$(docker inspect -f '{{.State.Pid}}' "$c")"
  ip link set "$vc" netns "$pid"
  docker exec "$c" sh -lc "
    ip link set lo up
    ip addr add $(node_lo "$i")/32 dev lo 2>/dev/null || true
    ip link set $vc name veth_0
    ip link set veth_0 up
    ip addr flush dev veth_0
    ip addr add $(node_ip "$i")/16 dev veth_0
  "
  disable_container_offloads "$c" "veth_0"
}

render_star_policy() {
  local out="${1:-$SIM_POLICY_GEN}"
  python3 - "$NODES" "$LAB_ID" "$out" <<'PY'
import json
import subprocess
import sys

n = int(sys.argv[1])
lab_id = sys.argv[2]
out = sys.argv[3]
center = 1

def sh(cmd):
    return subprocess.check_output(cmd, shell=True, text=True).strip()

mac = {}
for i in range(1, n + 1):
    c = f"{lab_id}_r_{i}"
    m = sh(f"docker exec {c} cat /sys/class/net/veth_0/address | tr '[:upper:]' '[:lower:]'")
    mac[i] = m

rules = []
for i in range(2, n + 1):
    rules.append({"src_mac": mac[center], "dst_mac": mac[i], "pkt_type": "unicast", "action": "forward"})
    rules.append({"src_mac": mac[i], "dst_mac": mac[center], "pkt_type": "unicast", "action": "forward"})

for i in range(1, n + 1):
    rules.append({"src_mac": mac[i], "pkt_type": "arp_broadcast", "action": "forward"})
    rules.append({"src_mac": mac[i], "pkt_type": "broadcast", "action": "drop"})

policy = {
    "version": "1.0",
    "default_action": "drop",
    "notes": "star topology center simulator policy",
    "rules": rules,
}

with open(out, 'w', encoding='utf-8') as f:
    json.dump(policy, f, indent=2)
    f.write('\n')
print(f"[ok] policy={out} rules={len(rules)}")
PY
}

ensure_sim() {
  local policy="${SIM_POLICY:-$SIM_POLICY_GEN}"

  docker rm -f "$SIM_C" >/dev/null 2>&1 || true
  docker run -d --name "$SIM_C" --hostname "$SIM_C" --network none --privileged "$IMG_SIM" tail -f /dev/null >/dev/null

  ip link del "$SIM_IN_H" 2>/dev/null || true
  ip link del "$SIM_OUT_H" 2>/dev/null || true
  ip link add "$SIM_IN_H" type veth peer name "$SIM_IN_C"
  ip link add "$SIM_OUT_H" type veth peer name "$SIM_OUT_C"
  ip link set "$SIM_IN_H" up
  ip link set "$SIM_OUT_H" up
  disable_host_offloads "$SIM_IN_H"
  disable_host_offloads "$SIM_OUT_H"

  ovs-vsctl --may-exist add-port "$BR" "$SIM_IN_H" -- set Interface "$SIM_IN_H" ofport_request=400
  ovs-vsctl --may-exist add-port "$BR" "$SIM_OUT_H" -- set Interface "$SIM_OUT_H" ofport_request=401

  local pid
  pid="$(docker inspect -f '{{.State.Pid}}' "$SIM_C")"
  ip link set "$SIM_IN_C" netns "$pid"
  ip link set "$SIM_OUT_C" netns "$pid"

  docker exec "$SIM_C" sh -lc "
    mkdir -p /opt/sim
    ip link set lo up
    ip link set ${SIM_IN_C} name sim_in
    ip link set ${SIM_OUT_C} name sim_out
    ip link set sim_in up
    ip link set sim_out up
  "
  disable_container_offloads "$SIM_C" "sim_in"
  disable_container_offloads "$SIM_C" "sim_out"

  docker cp "$policy" "$SIM_C:$SIM_POLICY_IN_C"
  docker cp "$ROOT/simulator_l2_center_sim.py" "$SIM_C:$SIM_PROG_IN_C"
  docker exec -d "$SIM_C" sh -lc "python3 $SIM_PROG_IN_C --in-if sim_in --out-if sim_out --policy $SIM_POLICY_IN_C > /tmp/sim.log 2>&1"
  sleep 1
}

apply_flows() {
  local ff="$STATE_DIR/flows.txt"
  local actions=""
  : > "$ff"

  echo "table=0,priority=0,actions=drop" >> "$ff"

  for i in $(seq 1 "$NODES"); do
    echo "table=0,priority=3000,in_port=${i},actions=output:400" >> "$ff"
  done

  for i in $(seq 1 "$NODES"); do
    local c="${PREFIX}_${i}"
    local mac
    mac="$(docker exec "$c" cat /sys/class/net/veth_0/address | tr '[:upper:]' '[:lower:]')"
    if [[ -n "$mac" ]]; then
      echo "table=0,priority=4100,in_port=401,dl_dst=${mac},actions=output:${i}" >> "$ff"
    fi
  done

  for i in $(seq 1 "$NODES"); do
    if [[ -z "$actions" ]]; then actions="output:${i}"; else actions="${actions},output:${i}"; fi
  done
  echo "table=0,priority=4050,in_port=401,dl_dst=ff:ff:ff:ff:ff:ff,actions=${actions}" >> "$ff"

  ovs-ofctl del-flows "$BR"
  ovs-ofctl add-flows "$BR" "$ff"
}

do_up() {
  ensure_prereqs
  render_neighbors

  ovs-vsctl --may-exist add-br "$BR"
  ovs-vsctl set-fail-mode "$BR" secure
  ovs-ofctl del-flows "$BR" || true
  ovs-ofctl add-flow "$BR" "table=0,priority=0,actions=drop"

  for i in $(seq 1 "$NODES"); do
    ensure_node "$i"
    if (( i % 50 == 0 || i == NODES )); then
      echo "[$LAB_ID] progress $i/$NODES"
    fi
  done

  render_star_policy "$SIM_POLICY_GEN"
  ensure_sim
  apply_flows
  echo "[$LAB_ID] up done"
}

do_down() {
  ensure_prereqs
  for i in $(seq 1 "$NODES"); do
    docker rm -f "${PREFIX}_${i}" >/dev/null 2>&1 || true
    ip link del "${IF_TAG}h_${i}" 2>/dev/null || true
  done
  docker rm -f "$SIM_C" >/dev/null 2>&1 || true
  ip link del "$SIM_IN_H" 2>/dev/null || true
  ip link del "$SIM_OUT_H" 2>/dev/null || true
  ovs-vsctl --if-exists del-br "$BR"
  rm -rf "$STATE_DIR"
  echo "[$LAB_ID] down done"
}

do_status() {
  ensure_prereqs
  echo "lab=$LAB_ID br=$BR nodes=$NODES"
  ovs-vsctl br-exists "$BR" && echo "bridge_exists=yes" || echo "bridge_exists=no"
  echo "running_nodes=$(docker ps --format '{{.Names}}' | grep -E '^'"${PREFIX}"'_r_[0-9]+$' | wc -l)"
  echo "sim_running=$(docker ps --format '{{.Names}}' | grep -E '^'"${SIM_C}"'$' | wc -l)"
}

case "$ACTION" in
  up) do_up ;;
  down) do_down ;;
  status) do_status ;;
  *)
    echo "usage: $0 {up|down|status}" >&2
    exit 2
    ;;
esac
