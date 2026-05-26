#!/bin/bash
# setup-volume.sh — Provision a new RBD-backed NVMe-oF volume end-to-end.
#
# What it does (idempotent — re-runs are safe):
#   1. Create the RBD image in nvmeof + nvmeof-data (skip if exists)
#   2. Create the NVMe-oF subsystem (skip if exists)
#   3. Attach the image as namespace `nsid`
#   4. Register a listener on each gateway (uses --force; needed for our
#      hostNetwork + unshare-UTS setup where ceph-nvmeof's host-name
#      check would otherwise reject same-host pairs)
#   5. Either open access to any host (default), or restrict to a single
#      host NQN passed via --host-nqn
#   6. Print the connect command(s) for the initiator side
#
# Usage:
#   ./setup-volume.sh -i <image-name> -s <size> [-n <nqn-tail>] [-h <host-nqn>]
#
# Examples:
#   ./setup-volume.sh -i workload-01 -s 100G
#   ./setup-volume.sh -i db-vol -s 1T -n nqn.2026-05.io.alcg:db
#   ./setup-volume.sh -i secure -s 50G \
#       -h nqn.2014-08.org.nvmexpress:uuid:11111111-2222-3333-4444-555555555555

set -euo pipefail

# -------------------------------------------------------------------- defaults
POOL_META=${POOL_META:-nvmeof}
POOL_DATA=${POOL_DATA:-nvmeof-data}
GROUP=${GROUP:-rbd-default}
SM3=${SM3:-10.144.27.26}
GW_A_PORT=${GW_A_PORT:-5500}
GW_B_PORT=${GW_B_PORT:-5501}
GW_A_DATA=${GW_A_DATA:-4420}
GW_B_DATA=${GW_B_DATA:-4421}
CLI_IMAGE=${CLI_IMAGE:-quay.io/ceph/nvmeof-cli:1.6.14}
NSID=${NSID:-1}

IMAGE=""
SIZE=""
NQN_TAIL=""
HOST_NQN='*'

while getopts ":i:s:n:h:" opt; do
  case $opt in
    i) IMAGE=$OPTARG ;;
    s) SIZE=$OPTARG ;;
    n) NQN_TAIL=$OPTARG ;;
    h) HOST_NQN=$OPTARG ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

if [ -z "${IMAGE}" ] || [ -z "${SIZE}" ]; then
  cat <<'EOF' >&2
usage: setup-volume.sh -i <image-name> -s <size> [-n <nqn>] [-h <host-nqn>]
  -i  RBD image name (lives in $POOL_META)
  -s  Size; passed to `rbd create --size` (e.g. 100G, 5T)
  -n  Override the subsystem NQN. Default: nqn.2026-05.io.alcg:<image>
      (ceph-nvmeof appends ".rbd-default" automatically.)
  -h  Initiator host NQN to allow. Default '*' (any host). Pass the
      client's /etc/nvme/hostnqn for restricted access.

env overrides:  POOL_META, POOL_DATA, GROUP, SM3, GW_{A,B}_PORT,
                GW_{A,B}_DATA, CLI_IMAGE, NSID
EOF
  exit 2
fi

NQN_BASE=${NQN_TAIL:-nqn.2026-05.io.alcg:${IMAGE}}
NQN="${NQN_BASE}.${GROUP}"   # ceph-nvmeof auto-appends the group name

# ----------------------------------------------------- helper: nvmeof-cli pod
cli() {
  local port=$1; shift
  kubectl run nvmeof-cli-$$ --rm -i --restart=Never --quiet \
    --image="${CLI_IMAGE}" \
    --command -- python3 -m control.cli \
      --server-address "${SM3}" --server-port "${port}" "$@"
}

echo "==> Provisioning NVMe-oF volume"
echo "    image      = ${POOL_META}/${IMAGE}  (size=${SIZE}, data-pool=${POOL_DATA})"
echo "    subsystem  = ${NQN}"
echo "    listeners  = ${SM3}:${GW_A_DATA} (gw-a), ${SM3}:${GW_B_DATA} (gw-b)"
echo "    host allow = ${HOST_NQN}"
echo

# ---------------------------------------------------------- 1. RBD image
echo "[1/5] RBD image ${POOL_META}/${IMAGE}"
if rbd info "${POOL_META}/${IMAGE}" &>/dev/null; then
  echo "      already exists — leaving alone"
else
  rbd create "${POOL_META}/${IMAGE}" \
      --size "${SIZE}" \
      --data-pool "${POOL_DATA}" \
      --image-feature layering,exclusive-lock,object-map,fast-diff,deep-flatten
  echo "      created"
fi

# ---------------------------------------------------------- 2. Subsystem
echo "[2/5] subsystem ${NQN}"
if cli "${GW_A_PORT}" subsystem list 2>/dev/null | grep -q "${NQN}"; then
  echo "      already exists — leaving alone"
else
  cli "${GW_A_PORT}" subsystem add --subsystem "${NQN}" --max-namespaces 32 --no-group-append-nqn || true
  echo "      created"
fi

# ---------------------------------------------------------- 3. Namespace
echo "[3/5] namespace nsid=${NSID} → ${POOL_META}/${IMAGE}"
if cli "${GW_A_PORT}" namespace list --subsystem "${NQN}" 2>/dev/null | grep -q "\| ${NSID} \|"; then
  echo "      already exists — leaving alone"
else
  cli "${GW_A_PORT}" namespace add \
      --subsystem "${NQN}" \
      --rbd-pool  "${POOL_META}" \
      --rbd-image "${IMAGE}" \
      --nsid      "${NSID}"
  echo "      added"
fi

# ---------------------------------------------------------- 4. Listeners
add_listener() {
  local port=$1 gw=$2 dataport=$3
  if cli "${port}" listener list --subsystem "${NQN}" 2>/dev/null \
     | grep -q "${SM3}.*${dataport}"; then
    echo "      ${gw} @ ${SM3}:${dataport} — already registered"
  else
    cli "${port}" listener add --subsystem "${NQN}" \
        --host-name "${gw}" \
        --traddr "${SM3}" --trsvcid "${dataport}" \
        --adrfam ipv4 --force
    echo "      ${gw} @ ${SM3}:${dataport} — added"
  fi
}

echo "[4/5] listeners"
add_listener "${GW_A_PORT}" gw-a "${GW_A_DATA}"
add_listener "${GW_B_PORT}" gw-b "${GW_B_DATA}"

# ---------------------------------------------------------- 5. Host allow
echo "[5/5] host allow-list"
cli "${GW_A_PORT}" host add --subsystem "${NQN}" --host-nqn "${HOST_NQN}" || true
echo "      ${HOST_NQN}"

# ---------------------------------------------------------- summary
cat <<EOF

==> Done. From an Ubuntu 24.04 (or any nvme-cli 2.x) initiator:

  sudo apt-get install -y nvme-cli
  sudo modprobe nvme-tcp
  test -f /etc/nvme/hostnqn || sudo bash -c \\
    'echo "nqn.2014-08.org.nvmexpress:uuid:\$(uuidgen)" > /etc/nvme/hostnqn'

  sudo nvme discover  -t tcp -a ${SM3} -s 8009
  sudo nvme connect-all -t tcp -a ${SM3} -s 8009 \\
      --hostnqn=\$(cat /etc/nvme/hostnqn)

  sudo nvme list-subsys                       # two 'live' controllers
  lsblk -o NAME,SIZE,MODEL | grep "Ceph bdev" # find the device
  sudo mkfs.ext4 -F /dev/nvmeXn1              # then mount

  # Persistent across reboots — use /dev/disk/by-id/nvme-Ceph_bdev_*

To tear down later:

  ./teardown-volume.sh -i ${IMAGE}            # (not yet provided — manual today)
  # or, manually:
  #   client:  sudo nvme disconnect -n ${NQN}
  #   cluster: cli ${GW_A_PORT} namespace del --subsystem ${NQN} --nsid ${NSID}
  #            cli ${GW_A_PORT} subsystem del --subsystem ${NQN} --force
  #            rbd rm ${POOL_META}/${IMAGE}

EOF
