#!/bin/bash
# connect-volume.sh — Attach an NVMe-oF volume from a Linux client.
#
# Why this exists (vs. `nvme discover -s 8009 && nvme connect-all`):
#   The centralized discovery controller on :8009 has been observed
#   to accept TCP but hang the discovery log fetch. This script
#   bypasses discovery entirely and issues explicit `nvme connect`
#   calls to both gateway data ports using the known NQN — which is
#   deterministic for volumes provisioned by setup-volume.sh.
#
# What it does (idempotent — re-runs are safe):
#   1. Load the nvme-tcp transport module
#   2. Generate /etc/nvme/hostnqn if missing
#   3. Connect to both gateway data ports for ${NQN}
#   4. Print the resulting subsys + by-id device path
#   5. Print the systemctl-enable + fstab snippets for persistence
#
# Usage (run as root):
#   sudo ./connect-volume.sh -i <image-name> [-n <nqn-tail>]
#
# Examples:
#   sudo ./connect-volume.sh -i workload-02
#   sudo ./connect-volume.sh -i secure -n nqn.2026-05.io.alcg:secure
#
# Pair with the systemd template `nvmeof-volume@.service` from this
# same directory to make the connection survive reboot.

set -euo pipefail

# -------------------------------------------------------------------- defaults
GROUP=${GROUP:-rbd-default}
SM3=${SM3:-10.144.27.26}
GW_A_DATA=${GW_A_DATA:-4420}
GW_B_DATA=${GW_B_DATA:-4421}

IMAGE=""
NQN_TAIL=""

while getopts ":i:n:" opt; do
  case $opt in
    i) IMAGE=$OPTARG ;;
    n) NQN_TAIL=$OPTARG ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

if [ -z "${IMAGE}" ]; then
  cat <<'EOF' >&2
usage: connect-volume.sh -i <image-name> [-n <nqn>]
  -i  RBD image name (must match what setup-volume.sh provisioned)
  -n  Override the base NQN. Default: nqn.2026-05.io.alcg:<image>
      (the ".rbd-default" group suffix is added automatically)

env overrides:  GROUP, SM3, GW_A_DATA, GW_B_DATA
EOF
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "connect-volume.sh must be run as root (nvme-cli needs CAP_NET_ADMIN)" >&2
  exit 1
fi

NQN_BASE=${NQN_TAIL:-nqn.2026-05.io.alcg:${IMAGE}}
NQN="${NQN_BASE}.${GROUP}"

echo "==> Attaching NVMe-oF volume"
echo "    subsystem  = ${NQN}"
echo "    gateways   = ${SM3}:${GW_A_DATA}, ${SM3}:${GW_B_DATA}"
echo

# ---------------------------------------------------------- 1. Transport
echo "[1/4] kernel module nvme-tcp"
if lsmod | grep -q '^nvme_tcp '; then
  echo "      already loaded"
else
  modprobe nvme-tcp
  echo "      loaded"
fi

# ---------------------------------------------------------- 2. Host NQN
echo "[2/4] host NQN"
install -d -m 755 /etc/nvme
if [ ! -f /etc/nvme/hostnqn ]; then
  echo "nqn.2014-08.org.nvmexpress:uuid:$(uuidgen)" > /etc/nvme/hostnqn
  echo "      generated /etc/nvme/hostnqn"
fi
echo "      $(cat /etc/nvme/hostnqn)"

# ---------------------------------------------------------- 3. Connect both paths
connect_path() {
  local port=$1
  if nvme list-subsys 2>/dev/null \
     | grep -q "traddr=${SM3},trsvcid=${port}"; then
    echo "      ${SM3}:${port} — already connected"
  else
    # nvme connect prints "connecting to device: nvmeN" on success.
    if nvme connect -t tcp -a "${SM3}" -s "${port}" -n "${NQN}" 2>&1; then
      :
    else
      echo "WARNING: connect to ${SM3}:${port} failed" >&2
    fi
  fi
}

echo "[3/4] connect paths"
connect_path "${GW_A_DATA}"
connect_path "${GW_B_DATA}"

# ---------------------------------------------------------- 4. Device discovery
echo "[4/4] block device"
sleep 1   # let udev settle the by-id symlinks
nvme list-subsys "${NQN}" 2>/dev/null || nvme list-subsys

BYID=$(ls -1 /dev/disk/by-id/ 2>/dev/null \
         | grep -E "^nvme-Ceph_bdev_Controller_[^_]+$" \
         | head -n1 || true)

if [ -n "${BYID}" ]; then
  DEV=$(readlink -f "/dev/disk/by-id/${BYID}")
  echo
  echo "    device     = ${DEV}"
  echo "    by-id      = /dev/disk/by-id/${BYID}"
else
  echo "    (no Ceph bdev device visible yet — check 'lsblk' or rerun)"
fi

# ---------------------------------------------------------- summary
cat <<EOF

==> Connected. To make it persistent across reboots:

  # 1. Install the per-volume connect unit (template from this repo):
  sudo cp nvmeof-volume@.service /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable nvmeof-volume@${IMAGE}.service

  # 2. Add an fstab entry (substitute <fs> and pick a mountpoint):
  echo "/dev/disk/by-id/${BYID:-nvme-Ceph_bdev_Controller_<serial>} \\
    /mnt/${IMAGE} <fs> \\
    defaults,_netdev,nofail,x-systemd.requires=nvmeof-volume@${IMAGE}.service \\
    0 2" | sudo tee -a /etc/fstab

  # 3. (One-time) format and mount:
  sudo mkfs.xfs /dev/disk/by-id/${BYID:-nvme-Ceph_bdev_Controller_<serial>}
  sudo mkdir -p /mnt/${IMAGE}
  sudo mount /mnt/${IMAGE}

To disconnect:
  sudo nvme disconnect -n ${NQN}

EOF
