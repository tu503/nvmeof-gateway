#!/bin/bash
# build-image.sh — Layer the homelab's tu503/ceph librbd over upstream
# ceph-nvmeof container, so the gateway speaks the same Ceph build the
# cluster is running.
#
# Base: quay.io/ceph/nvmeof:<NVMEOF_TAG>
#   - SPDK nvmf_tgt + ceph-nvmeof Python control plane already wired
#   - bundles librbd built against upstream 20.2.1
# Overlay (from /usr/lib64 on this host):
#   - librbd.so.1 + .so.2 (versioned, plus symlinks)
#   - librados.so.2
#   - ceph-nvmeof-monitor-client (so the gateway's beacons match what
#     our rebuilt ceph-mon expects)
#   - rados-classes/* (cls plugins librbd loads at runtime)
#
# Usage: ./build-image.sh [tag]
# Pin:   NVMEOF_TAG=1.6.14 (tentacle_9.1)

set -euo pipefail

NVMEOF_TAG=${NVMEOF_TAG:-1.6.14}
CEPH_VERSION=$(qatom -F '%{PV}' "$(qlist -ICv sys-cluster/ceph)" 2>/dev/null \
              | head -1 || echo 20.x)
TAG="${1:-v${CEPH_VERSION}-nvmeof-${NVMEOF_TAG}}"
BASE_IMAGE="quay.io/ceph/nvmeof:${NVMEOF_TAG}"
IMAGE="registry.alcg.io/ceph-nvmeof:${TAG}"

echo "=== ceph-nvmeof image: ${IMAGE} ==="
echo "  base          = ${BASE_IMAGE}"
echo "  ceph_version  = ${CEPH_VERSION} (homelab tu503/ceph ceph-999)"
echo

echo "[1/3] Pulling upstream base..."
buildah pull "${BASE_IMAGE}"

echo "[2/3] Layering host's Ceph binaries..."
ctr=$(buildah from "${BASE_IMAGE}")
mnt=$(buildah mount "$ctr")

# --- librbd / librados — overlay the whole symlink chain ---
for stem in librbd librados; do
  # Find every file matching libfoo.so* on host
  while read -r src; do
    name=$(basename "$src")
    if [ -L "$src" ]; then
      target=$(readlink "$src")
      ln -sfT "$target" "${mnt}/usr/lib64/${name}"
    else
      cp -a "$src" "${mnt}/usr/lib64/${name}"
    fi
    echo "  overlay /usr/lib64/${name}"
  done < <(ls /usr/lib64/${stem}.so* 2>/dev/null)
done

# --- ceph-nvmeof-monitor-client ---
if [ -f /usr/bin/ceph-nvmeof-monitor-client ]; then
  cp /usr/bin/ceph-nvmeof-monitor-client "${mnt}/usr/bin/ceph-nvmeof-monitor-client"
  echo "  overlay /usr/bin/ceph-nvmeof-monitor-client"
fi

# --- RADOS class plugins (cls/rbd, cls/lock, cls/version, ...) ---
if [ -d /usr/lib64/rados-classes ]; then
  mkdir -p "${mnt}/usr/lib64/rados-classes"
  cp -af /usr/lib64/rados-classes/. "${mnt}/usr/lib64/rados-classes/"
  echo "  overlay /usr/lib64/rados-classes/ ($(ls /usr/lib64/rados-classes | wc -l) plugins)"
fi

# --- ldconfig inside the container so the new libs are discoverable ---
buildah run "$ctr" -- /sbin/ldconfig 2>/dev/null || true

echo "[3/3] Committing image..."
buildah unmount "$ctr"
buildah commit "$ctr" "${IMAGE}"
buildah rm "$ctr"

echo
echo "=== Built: ${IMAGE} ==="
echo "Size: $(buildah images --format '{{.Size}}' "${IMAGE}" 2>&1)"
echo
echo "Push + import for k8s:"
echo "  buildah push ${IMAGE} oci-archive:/tmp/ceph-nvmeof.tar"
echo "  ctr -n k8s.io images import /tmp/ceph-nvmeof.tar --tag ${IMAGE}"
