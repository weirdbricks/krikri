#!/usr/bin/env bash
#
# Kata test hosts: real VMs with a real kernel and a real systemd, on the
# local machine. See README.md for why, and for every gotcha encoded below.
#
#   ./kata-host.sh up   <name> <octet> [image]   -> boot, wait for ssh, print IP
#   ./kata-host.sh down <name>                   -> tear down completely
#   ./kata-host.sh ip   <name>                   -> print the IP
#
# Requires the NOPASSWD sudoers entry for ctr/ip/kill (see README.md).
set -uo pipefail

SUBNET="10.99"
IMAGE_DEFAULT="localhost/kata-krikri-systemd:latest"
KEY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/key"

ns_of()   { echo "ns-$1"; }
hostif()  { echo "$1-h"; }
guestif() { echo "$1-c"; }
ip_of()   { echo "$SUBNET.$2.2"; }
gw_of()   { echo "$SUBNET.$2.1"; }

# Kill order matters. `ctr task kill` talks to the kata agent INSIDE the VM
# over the sandbox network; if that network is gone (say the netns was
# recreated under a live VM) the call hangs forever rather than failing. So:
# ask nicely with a timeout, then kill the shim/VMM processes directly.
force_down() {
  local name="$1"
  timeout 20 sudo -n ctr task kill -a -s SIGKILL "$name" >/dev/null 2>&1
  sleep 2
  # containerd-shim-kata-v2 and its children (qemu/cloud-hypervisor, virtiofsd)
  local shim
  shim=$(pgrep -f "containerd-shim-kata-v2.*$name" 2>/dev/null | head -1)
  if [ -n "${shim:-}" ]; then
    local kids
    kids=$(pgrep -P "$shim" 2>/dev/null | tr '\n' ' ')
    # shellcheck disable=SC2086
    sudo -n kill -9 $kids "$shim" >/dev/null 2>&1
    sleep 2
  fi
  timeout 20 sudo -n ctr task rm -f "$name"      >/dev/null 2>&1
  timeout 20 sudo -n ctr container rm "$name"    >/dev/null 2>&1
  timeout 20 sudo -n ctr snapshot rm "$name"     >/dev/null 2>&1
}

net_down() {
  local name="$1"
  sudo -n ip netns del "$(ns_of "$name")" >/dev/null 2>&1
  sudo -n ip link del "$(hostif "$name")" >/dev/null 2>&1
}

# A netns is single-use. Kata drops a `tap0_kata` device and a tc ingress
# filter into it, and on the NEXT run refuses the same netns with either
# "unsupported link type: tuntap" or "add virt ingress ... File exists".
# Recreating it from scratch every time is the whole fix.
net_up() {
  local name="$1" octet="$2"
  local ns hif gif
  ns=$(ns_of "$name"); hif=$(hostif "$name"); gif=$(guestif "$name")
  net_down "$name"
  sudo -n ip netns add "$ns"                                     || return 1
  sudo -n ip link add "$hif" type veth peer name "$gif"           || return 1
  sudo -n ip link set "$gif" netns "$ns"                          || return 1
  sudo -n ip addr add "$(gw_of "$name" "$octet")/24" dev "$hif"   || return 1
  sudo -n ip link set "$hif" up                                   || return 1
  sudo -n ip -n "$ns" addr add "$(ip_of "$name" "$octet")/24" dev "$gif" || return 1
  sudo -n ip -n "$ns" link set "$gif" up                          || return 1
  sudo -n ip -n "$ns" link set lo up                              || return 1
}

up() {
  local name="$1" octet="$2" image="${3:-$IMAGE_DEFAULT}"
  local ip; ip=$(ip_of "$name" "$octet")

  force_down "$name"
  net_up "$name" "$octet" || { echo "network setup failed" >&2; return 1; }

  # --privileged is what makes /proc/sys writable, which is what makes
  #   `sysctl -w` (the whole os_hardening class) work at all. On its own it
  #   fails under Kata - it tries to pass every host device into the VM and
  #   dies with "get host path failed" - so it MUST be paired with
  #   --privileged-without-host-devices.
  # container=docker is what makes systemd take its containerized boot path;
  #   without it PID 1 exits immediately and silently.
  # tmpfs on /run and /run/lock is the rest of what podman's --systemd does.
  timeout 180 sudo -n ctr run -d \
    --runtime io.containerd.kata.v2 \
    --with-ns "network:/var/run/netns/$(ns_of "$name")" \
    --privileged --privileged-without-host-devices \
    --env container=docker \
    --mount type=tmpfs,src=tmpfs,dst=/run,options=rw:nosuid:nodev:mode=755 \
    --mount type=tmpfs,src=tmpfs,dst=/run/lock,options=rw:nosuid:nodev:mode=1777 \
    "$image" "$name" /sbin/init || { echo "ctr run failed" >&2; return 1; }

  for _ in $(seq 1 40); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=3 -o LogLevel=ERROR -i "$KEY" "root@$ip" true 2>/dev/null; then
      echo "$ip"
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for ssh on $ip" >&2
  return 1
}

down() { force_down "$1"; net_down "$1"; }

case "${1:-}" in
  up)   up   "${2:?name}" "${3:?octet}" "${4:-}" ;;
  down) down "${2:?name}" ;;
  ip)   ip_of "${2:?name}" "${3:?octet}" ;;
  *)    echo "usage: $0 {up <name> <octet> [image]|down <name>|ip <name> <octet>}" >&2; exit 2 ;;
esac
