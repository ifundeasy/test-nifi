#!/usr/bin/env bash
set -euo pipefail

# validate_docker_labnet.sh
# Validates that ubuntu1..ubuntu6 are running, have IPs, are on the same network,
# and can communicate with each other (DNS + ICMP ping). Optionally checks TCP port.
#
# Usage:
#   bash validate_docker_labnet.sh
#   COUNT=6 PREFIX=ubuntu bash validate_docker_labnet.sh
#   TCP_PORT=22 bash validate_docker_labnet.sh

COUNT="${COUNT:-6}"
PREFIX="${PREFIX:-ubuntu}"
TCP_PORT="${TCP_PORT:-}"   # e.g., 22 (optional)

containers=()
for i in $(seq 1 "$COUNT"); do
  containers+=("${PREFIX}${i}")
done

die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

need_cmd docker
need_cmd awk
need_cmd grep
need_cmd tr

echo "== Docker lab network validation =="
echo "Containers: ${containers[*]}"
echo

# Check containers exist and are running
echo "== 1) Container status =="
for c in "${containers[@]}"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    die "Container not found: $c"
  fi
  running="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo "false")"
  if [[ "$running" != "true" ]]; then
    die "Container not running: $c"
  fi
  echo "OK: $c is running"
done
echo

# Find a common user-defined bridge network all containers share
echo "== 2) Network membership =="
declare -A netset_count
declare -A container_nets

for c in "${containers[@]}"; do
  # List all networks for container
  nets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c" | tr -s ' ' | sed 's/ $//')"
  [[ -n "$nets" ]] || die "No networks found for $c"
  container_nets["$c"]="$nets"
  echo "$c networks: $nets"
  for n in $nets; do
    netset_count["$n"]=$(( ${netset_count["$n"]:-0} + 1 ))
  done
done

common_net=""
for n in "${!netset_count[@]}"; do
  if [[ "${netset_count["$n"]}" -eq "$COUNT" ]]; then
    common_net="$n"
    break
  fi
done

[[ -n "$common_net" ]] || die "No single common network shared by all containers (expected a user-defined bridge like *_labnet)."
echo
echo "Common network: $common_net"
echo

# Collect IPs on the common network
echo "== 3) IP addresses on $common_net =="
declare -A ipmap
for c in "${containers[@]}"; do
  ip="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$common_net\"}}{{.IPAddress}}{{end}}" "$c")"
  [[ -n "$ip" ]] || die "No IP found for $c on network $common_net"
  ipmap["$c"]="$ip"
  printf "%-10s -> %s\n" "$c" "$ip"
done
echo

# Ensure ping + basic tools exist; install if missing (requires sudo in container)
echo "== 4) Ensure tools inside containers (ping, getent, nc) =="
for c in "${containers[@]}"; do
  docker exec "$c" bash -lc 'command -v ping >/dev/null 2>&1 && command -v getent >/dev/null 2>&1 && command -v nc >/dev/null 2>&1' \
    && echo "OK: $c has ping/getent/nc" \
    || {
      echo "INFO: Installing iputils-ping + dnsutils + netcat on $c (requires sudo, password may be prompted)..."
      docker exec -it "$c" bash -lc 'sudo -S true >/dev/null 2>&1 || true; sudo apt-get update && sudo apt-get install -y iputils-ping dnsutils netcat-openbsd'
    }
done
echo

# DNS + ICMP matrix test
echo "== 5) Connectivity matrix (DNS + ping) =="
fail=0
for src in "${containers[@]}"; do
  for dst in "${containers[@]}"; do
    [[ "$src" == "$dst" ]] && continue

    dst_ip="${ipmap[$dst]}"

    # DNS resolve
    if docker exec "$src" bash -lc "getent hosts $dst >/dev/null 2>&1"; then
      dns_ok="DNS:OK"
    else
      dns_ok="DNS:FAIL"
      fail=$((fail+1))
    fi

    # Ping by IP (more deterministic than name)
    if docker exec "$src" bash -lc "ping -c 1 -W 1 $dst_ip >/dev/null 2>&1"; then
      ping_ok="PING:OK"
    else
      ping_ok="PING:FAIL"
      fail=$((fail+1))
    fi

    printf "%-10s -> %-10s (%s, %s)\n" "$src" "$dst" "$dns_ok" "$ping_ok"
  done
done
echo

# Optional TCP port check (requires something listening on dst)
if [[ -n "$TCP_PORT" ]]; then
  echo "== 6) Optional TCP check (port $TCP_PORT) =="
  # Note: Ubuntu containers won't have sshd listening unless you install/start it.
  for src in "${containers[@]}"; do
    for dst in "${containers[@]}"; do
      [[ "$src" == "$dst" ]] && continue
      dst_ip="${ipmap[$dst]}"
      if docker exec "$src" bash -lc "nc -z -w 1 $dst_ip $TCP_PORT >/dev/null 2>&1"; then
        printf "%-10s -> %-10s TCP:%s OK\n" "$src" "$dst" "$TCP_PORT"
      else
        printf "%-10s -> %-10s TCP:%s FAIL (no listener?)\n" "$src" "$dst" "$TCP_PORT"
        # Not counting as hard fail by default because port might not be open.
      fi
    done
  done
  echo
fi

if [[ "$fail" -gt 0 ]]; then
  die "Connectivity validation failed with $fail error(s). See output above."
fi

echo "SUCCESS: All containers can resolve each other (DNS) and ping each other (ICMP) on network: $common_net"
