#!/bin/bash
# build-image.sh — Build a ceph-nvmeof gateway OCI image.
#
# Bundles:
#   - SPDK target (`nvmf_tgt`) built from source. Upstream ceph-nvmeof
#     pins a specific SPDK fork branch in its submodule; we follow that
#     pin rather than using gentoo's bundled SPDK (which is built into
#     ceph-osd, not exposed as a standalone binary).
#   - librbd / librados / ceph-nvmeof-monitor-client from the host
#     `sys-cluster/ceph-999 USE="nvmeof spdk"` install — keeps cluster
#     compat exact (mirrors rgw-gateway/build-image.sh's pattern).
#   - Upstream ceph-nvmeof Python control plane at the pinned tag.
#   - All ldd-resolved shared library deps + a python stdlib.
#
# Usage: ./build-image.sh [tag]
# Pin: NVMEOF_TAG (default 1.6.14) selects the ceph-nvmeof release.
#      The SPDK branch is read out of ceph-nvmeof's .gitmodules at that
#      tag, so no need to set SPDK_BRANCH manually.

set -euo pipefail

# ceph --version on tentacle 20.1.1 reports "ceph version IT-NOTFOUND (sha)" —
# the third token isn't the version anymore. Pull from pkg DB instead.
CEPH_VERSION=$(qatom -F '%{PV}' "$(qlist -ICv sys-cluster/ceph)" 2>/dev/null \
              | head -1 || echo 20.x)
NVMEOF_TAG=${NVMEOF_TAG:-1.6.14}                    # tentacle_9.1 line
TAG="${1:-v${CEPH_VERSION}-nvmeof-${NVMEOF_TAG}}"
IMAGE="registry.alcg.io/ceph-nvmeof:${TAG}"

WORK=$(mktemp -d -t nvmeof-build-XXXX)
NVMEOF_SRC="${WORK}/ceph-nvmeof"
SPDK_SRC="${NVMEOF_SRC}/spdk"
SPDK_PREFIX="${WORK}/spdk-install"

cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

# Host artifacts
HOST_MONITOR_CLIENT="/usr/bin/ceph-nvmeof-monitor-client"
PYTHON_BIN=$(command -v python3)
PYTHON_VER=$("${PYTHON_BIN}" -c 'import sys; print(f"python{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_SITE="/usr/lib/${PYTHON_VER}/site-packages"

echo "=== ceph-nvmeof image: ${IMAGE} ==="
echo "  ceph_version    = ${CEPH_VERSION}"
echo "  nvmeof_tag      = ${NVMEOF_TAG}"
echo "  monitor_client  = ${HOST_MONITOR_CLIENT}"
echo "  python          = ${PYTHON_BIN} (${PYTHON_VER})"
echo "  work dir        = ${WORK}"
echo

# ============================================================================
# Stage 1 — fetch upstream ceph-nvmeof + SPDK submodule (its pinned branch)
# ============================================================================
echo "[1/5] Cloning ceph-nvmeof ${NVMEOF_TAG} + SPDK submodule..."
git clone --depth 1 --branch "${NVMEOF_TAG}" \
    https://github.com/ceph/ceph-nvmeof.git "${NVMEOF_SRC}"
(cd "${NVMEOF_SRC}" && git submodule update --init --depth 1 --recursive spdk)
echo "  spdk branch = $(cd ${SPDK_SRC} && git branch --show-current 2>/dev/null || git rev-parse HEAD)"

# ============================================================================
# Stage 2 — build SPDK from source
# ============================================================================
echo "[2/5] Building SPDK..."
(
  cd "${SPDK_SRC}"
  # Pull SPDK's own submodules (dpdk, isa-l, etc.)
  git submodule update --init --depth 1 --recursive
  # Configure: minimal modules, no kernel-aware features we don't use
  ./configure \
      --prefix="${SPDK_PREFIX}" \
      --with-rbd \
      --without-vfio-user \
      --without-uring \
      --without-rdma \
      --without-vhost \
      --without-virtio \
      --without-fsdev \
      --without-fc \
      --without-iscsi-initiator \
      --disable-tests \
      --disable-unit-tests \
      --disable-examples
  make -j"$(nproc)"
  make install
)
echo "  nvmf_tgt: $(ls -la ${SPDK_PREFIX}/bin/nvmf_tgt 2>&1)"

# ============================================================================
# Stage 3 — generate ceph-nvmeof gRPC python bindings
# ============================================================================
echo "[3/5] Generating ceph-nvmeof gRPC python bindings..."
# grpcio-tools isn't packaged on the gentoo host (and we don't site-pip-install
# on this host per project convention). Stage it into a per-build temp dir and
# point PYTHONPATH at that; it's GC'd by the cleanup trap.
GRPC_TOOLS_DIR="${WORK}/grpc-tools-tmp"
mkdir -p "${GRPC_TOOLS_DIR}"
"${PYTHON_BIN}" -m pip install --quiet --no-compile \
    --target="${GRPC_TOOLS_DIR}" \
    grpcio-tools
(
  cd "${NVMEOF_SRC}"
  PYTHONPATH="${GRPC_TOOLS_DIR}:${PYTHONPATH:-}" "${PYTHON_BIN}" -m grpc_tools.protoc \
      -I control/proto \
      --python_out=control/proto \
      --grpc_python_out=control/proto \
      --pyi_out=control/proto \
      control/proto/gateway.proto control/proto/monitor.proto
)

# ============================================================================
# Stage 4 — assemble the scratch container via buildah
# ============================================================================
echo "[4/5] Assembling scratch container..."
ctr=$(buildah from scratch)
mnt=$(buildah mount "$ctr")

mkdir -p \
    "${mnt}/usr/bin" \
    "${mnt}/usr/local/bin" \
    "${mnt}/usr/local/lib" \
    "${mnt}/usr/lib64/ceph" \
    "${mnt}/lib64" \
    "${mnt}/etc" \
    "${mnt}/var/tmp" \
    "${mnt}/dev/hugepages" \
    "${mnt}${PYTHON_SITE}" \
    "${mnt}/opt/ceph-nvmeof/control" \
    "${mnt}/opt/python-deps"

# --- SPDK runtime (binaries + libs from our build) ---
cp -r "${SPDK_PREFIX}/bin/."  "${mnt}/usr/local/bin/"
cp -r "${SPDK_PREFIX}/lib/."  "${mnt}/usr/local/lib/" 2>/dev/null || true
# Stage the python rpc helper too
[ -f "${SPDK_SRC}/scripts/rpc.py" ] && cp "${SPDK_SRC}/scripts/rpc.py" "${mnt}/usr/local/bin/spdk_rpc.py"

# --- Host Ceph bits ---
cp "${HOST_MONITOR_CLIENT}" "${mnt}/usr/bin/ceph-nvmeof-monitor-client"
cp "${PYTHON_BIN}"          "${mnt}/usr/bin/python3"
cp /lib64/ld-linux-x86-64.so.2 "${mnt}/lib64/"

# Host's compiled python bindings for rados/rbd
cp "${PYTHON_SITE}"/rados.cpython-*.so "${mnt}${PYTHON_SITE}/"
cp "${PYTHON_SITE}"/rbd.cpython-*.so   "${mnt}${PYTHON_SITE}/"

# --- ceph-nvmeof control plane (Python) ---
cp -r "${NVMEOF_SRC}/control/." "${mnt}/opt/ceph-nvmeof/control/"
ln -sfT /opt/ceph-nvmeof/control "${mnt}/control"

# --- pip-install runtime python deps for ceph-nvmeof ---
"${PYTHON_BIN}" -m pip install --no-compile --no-deps \
    --target="${mnt}/opt/python-deps" \
    -r "${NVMEOF_SRC}/requirements.txt"

# --- python stdlib (so `python3 -m control` can run with no host pythonpath) ---
mkdir -p "${mnt}/usr/lib/${PYTHON_VER}"
cp -a "/usr/lib/${PYTHON_VER}/." "${mnt}/usr/lib/${PYTHON_VER}/" 2>/dev/null || true

# ============================================================================
# Stage 5 — ldd-resolve every binary in the staged image (multi-pass)
# ============================================================================
echo "[5/5] Resolving shared library dependencies..."
copy_ldd() {
  local bin=$1
  ldd "$bin" 2>/dev/null | grep "=>" | awk '{print $3}' | sort -u | while read -r lib; do
    [ -z "$lib" ] && continue
    [ ! -f "$lib" ] && continue
    local depname; depname=$(basename "$lib")
    if [[ "$lib" == */ceph/* ]]; then
      [ -f "${mnt}/usr/lib64/ceph/${depname}" ] || cp "$lib" "${mnt}/usr/lib64/ceph/${depname}"
    else
      [ -f "${mnt}/usr/lib64/${depname}" ] || cp "$lib" "${mnt}/usr/lib64/${depname}"
    fi
  done
}

# First pass: every executable + .so we've already staged
for b in "${mnt}/usr/local/bin/nvmf_tgt" \
         "${mnt}/usr/bin/ceph-nvmeof-monitor-client" \
         "${mnt}/usr/bin/python3" \
         "${mnt}/usr/local/lib"/*.so* \
         "${mnt}${PYTHON_SITE}"/rados.cpython-*.so \
         "${mnt}${PYTHON_SITE}"/rbd.cpython-*.so; do
  [ -f "$b" ] && copy_ldd "$b"
done

# Recurse until no new deps found
prev_count=0
while :; do
  count=$(find "${mnt}/usr/lib64" "${mnt}/lib64" -name "*.so*" | wc -l)
  [ "$count" = "$prev_count" ] && break
  prev_count=$count
  for lib in "${mnt}"/usr/lib64/*.so* "${mnt}"/usr/lib64/ceph/*.so* "${mnt}"/lib64/*.so*; do
    [ -f "$lib" ] && copy_ldd "$lib"
  done
done
echo "  staged $(find ${mnt}/usr/lib64 ${mnt}/lib64 -name '*.so*' | wc -l) shared libs"

# --- minimal /etc ---
cat > "${mnt}/etc/nsswitch.conf" <<'EOF'
passwd: files
group:  files
hosts:  files dns
EOF
cat > "${mnt}/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:Nobody:/:/sbin/nologin
EOF
cat > "${mnt}/etc/group" <<'EOF'
root:x:0:
nobody:x:65534:
EOF

# ============================================================================
# Image config + commit
# ============================================================================
buildah config \
  --port 5500/tcp \
  --port 4420/tcp \
  --port 8009/tcp \
  --env "PYTHONPATH=/opt/python-deps:/opt/ceph-nvmeof:${PYTHON_SITE}" \
  --env "LD_LIBRARY_PATH=/usr/local/lib:/usr/lib64:/usr/lib64/ceph:/lib64" \
  --env "PATH=/usr/local/bin:/usr/bin" \
  --entrypoint '["/usr/bin/python3","-m","control"]' \
  "$ctr"

buildah unmount "$ctr"
buildah commit "$ctr" "${IMAGE}"
buildah rm "$ctr"

echo
echo "=== Built: ${IMAGE} ==="
echo "Size: $(buildah images --format '{{.Size}}' "${IMAGE}")"
echo
echo "Next:"
echo "  buildah push ${IMAGE} oci-archive:/tmp/ceph-nvmeof.tar"
echo "  ctr -n k8s.io images import /tmp/ceph-nvmeof.tar --tag ${IMAGE}"
