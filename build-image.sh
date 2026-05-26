#!/bin/bash
# build-image.sh — Build a ceph-nvmeof gateway OCI image entirely from
# local artifacts on sm3. No upstream container as base.
#
# What goes in:
#   - SPDK target (nvmf_tgt + libs) built from source. Upstream ceph-nvmeof
#     pins a specific SPDK fork branch (ceph-nvmeof-v25.09) in its
#     `spdk/` submodule; we follow that pin.
#   - librbd / librados / ceph-nvmeof-monitor-client from the host's
#     sys-cluster/ceph-999 install (with the homelab assert-relaxation
#     patch baked in via commit 72af74d4876 on tu503/ceph ceph-999).
#   - Host's python3.13 + the rados/rbd cython bindings, identical ABI.
#   - Upstream ceph-nvmeof Python control plane at tag 1.6.14 (no upstream
#     binaries from it — just the Python source + generated gRPC stubs).
#   - All ldd-resolved shared library deps from /usr/lib64 (gentoo glibc,
#     libstdc++.so.6 from gcc-15, libabsl_*, libgrpc, libprotobuf — same
#     ABI as the monitor-client expects since both come from this host).
#
# Build host requirements (sm3 has them all):
#   - sys-cluster/ceph-999 USE="nvmeof spdk" installed
#   - pyelftools (for DPDK's meson scripts in SPDK build)
#   - buildah
#   - git, gcc-15, make
#
# Usage:  ./build-image.sh [tag]
# Pin:    NVMEOF_TAG (default 1.6.14)

set -euo pipefail

# ----------------------------------------------------------- config + pins
CEPH_VERSION=$(qatom -F '%{PV}' "$(qlist -ICv sys-cluster/ceph)" 2>/dev/null \
              | head -1 || echo 20.x)
NVMEOF_TAG=${NVMEOF_TAG:-1.6.14}
TAG="${1:-v${CEPH_VERSION}-homelab}"
IMAGE="registry.alcg.io/ceph-nvmeof:${TAG}"

# Host artifacts
HOST_MONITOR_CLIENT=/usr/bin/ceph-nvmeof-monitor-client
PYTHON_BIN=$(command -v python3)
PYTHON_VER=$("${PYTHON_BIN}" -c 'import sys; print(f"python{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_SITE="/usr/lib/${PYTHON_VER}/site-packages"

# Work dir; trap cleans up unless KEEP_WORK=1
WORK=$(mktemp -d -t nvmeof-build-XXXX)
SPDK_PREFIX="${WORK}/spdk-install"
NVMEOF_SRC="${WORK}/ceph-nvmeof"
SPDK_SRC="${NVMEOF_SRC}/spdk"

cleanup() { [ "${KEEP_WORK:-0}" = "1" ] || rm -rf "${WORK}"; }
trap cleanup EXIT

echo "=== ceph-nvmeof image (fully local): ${IMAGE} ==="
echo "  ceph version    = ${CEPH_VERSION} (tu503/ceph ceph-999 + assert patch)"
echo "  ceph-nvmeof tag = ${NVMEOF_TAG}"
echo "  python          = ${PYTHON_BIN} (${PYTHON_VER})"
echo "  monitor-client  = ${HOST_MONITOR_CLIENT}"
echo "  work dir        = ${WORK}"
echo

# ============================================================================
# Stage 1 — fetch upstream ceph-nvmeof + its pinned SPDK submodule
# ============================================================================
echo "[1/5] Cloning ceph-nvmeof ${NVMEOF_TAG} + SPDK submodule..."
git clone --depth 1 --branch "${NVMEOF_TAG}" \
    https://github.com/ceph/ceph-nvmeof.git "${NVMEOF_SRC}"
(cd "${NVMEOF_SRC}" && git submodule update --init --depth 1 --recursive spdk)
echo "  spdk @ $(cd ${SPDK_SRC} && git rev-parse --short HEAD)"

# ============================================================================
# Stage 2 — patch + build SPDK from source
# ============================================================================
echo "[2/5] Building SPDK from source..."
(
  cd "${SPDK_SRC}"
  git submodule update --init --depth 1 --recursive

  # ceph/spdk's bdev_rbd uses rbd_aio_write_with_crc32c — only in ceph/ceph
  # fork's librbd, not in our 20.1.1+patches build. Stub to plain rbd_aio_write.
  if ! grep -q "homelab: stub rbd_aio_write_with_crc32c" module/bdev/rbd/bdev_rbd.c; then
    sed -i '1i\
/* homelab: stub rbd_aio_write_with_crc32c -> rbd_aio_write (vanilla librbd has\
 * no CRC32 fast-path API; see ceph-nvmeof/spdk ceph-nvmeof-v25.09 branch). */\
#define rbd_aio_write_with_crc32c(image, off, len, buf, crc, comp, flags) \\\
    rbd_aio_write((image), (off), (len), (buf), (comp))\
' module/bdev/rbd/bdev_rbd.c
  fi

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

  make -j"$(nproc)" >/dev/null
  make install >/dev/null
)
echo "  nvmf_tgt: $(ls -la ${SPDK_PREFIX}/bin/nvmf_tgt)"
echo "  spdk libs: $(ls ${SPDK_PREFIX}/lib | wc -l) files"

# ============================================================================
# Stage 3 — generate ceph-nvmeof gRPC python bindings
# ============================================================================
echo "[3/5] Generating ceph-nvmeof gRPC python bindings..."
GRPC_TOOLS_STAGE="${WORK}/grpc-tools-stage"
mkdir -p "${GRPC_TOOLS_STAGE}"
# grpcio_tools relaxed to >= to use Py3.13 wheels
"${PYTHON_BIN}" -m pip install --quiet --no-compile \
    --target="${GRPC_TOOLS_STAGE}" \
    "grpcio_tools>=1.71"
(
  cd "${NVMEOF_SRC}"
  PYTHONPATH="${GRPC_TOOLS_STAGE}" "${PYTHON_BIN}" -m grpc_tools.protoc \
      -I control/proto \
      --python_out=control/proto \
      --grpc_python_out=control/proto \
      --pyi_out=control/proto \
      control/proto/gateway.proto control/proto/monitor.proto
)

# ============================================================================
# Stage 4 — assemble the container via buildah (scratch base)
# ============================================================================
echo "[4/5] Assembling scratch container..."
ctr=$(buildah from scratch)
mnt=$(buildah mount "$ctr")

mkdir -p \
    "${mnt}/usr/bin" \
    "${mnt}/usr/local/bin" \
    "${mnt}/usr/local/lib" \
    "${mnt}/usr/lib64/ceph" \
    "${mnt}/usr/lib64/rados-classes" \
    "${mnt}/lib64" \
    "${mnt}/etc" \
    "${mnt}/var/tmp" \
    "${mnt}/dev/hugepages" \
    "${mnt}${PYTHON_SITE}" \
    "${mnt}/opt/ceph-nvmeof/control" \
    "${mnt}/opt/python-deps"

# --- ld-linux (the dynamic linker — required first) ---
cp /lib64/ld-linux-x86-64.so.2 "${mnt}/lib64/"

# --- SPDK runtime (from our just-built sources) ---
cp -r "${SPDK_PREFIX}/bin/."  "${mnt}/usr/local/bin/"
cp -r "${SPDK_PREFIX}/lib/."  "${mnt}/usr/local/lib/" 2>/dev/null || true
[ -f "${SPDK_SRC}/scripts/rpc.py" ] && cp "${SPDK_SRC}/scripts/rpc.py" "${mnt}/usr/local/bin/spdk_rpc.py"

# --- Host Ceph binaries (patched ceph-nvmeof-monitor-client lives here) ---
cp "${HOST_MONITOR_CLIENT}" "${mnt}/usr/bin/"
cp "${PYTHON_BIN}"          "${mnt}/usr/bin/python3"

# --- RADOS class plugins (cls/rbd etc.) ---
cp -af /usr/lib64/rados-classes/. "${mnt}/usr/lib64/rados-classes/" 2>/dev/null || true

# --- Host's compiled python bindings for rados/rbd ---
cp "${PYTHON_SITE}"/rados.cpython-*.so "${mnt}${PYTHON_SITE}/"
cp "${PYTHON_SITE}"/rbd.cpython-*.so   "${mnt}${PYTHON_SITE}/"

# --- ceph-nvmeof Python control plane ---
cp -r "${NVMEOF_SRC}/control/." "${mnt}/opt/ceph-nvmeof/control/"
ln -sfT /opt/ceph-nvmeof/control "${mnt}/control"

# --- ceph-nvmeof.conf included in the upstream tag (for reference) ---
cp "${NVMEOF_SRC}/ceph-nvmeof.conf" "${mnt}/etc/ceph-nvmeof.conf.example" 2>/dev/null || true

# --- pip-install ceph-nvmeof Python runtime deps ---
echo "  installing ceph-nvmeof python deps..."
DEPS=$("${PYTHON_BIN}" - <<EOF
import re, tomllib
with open("${NVMEOF_SRC}/pyproject.toml", "rb") as f:
    deps = tomllib.load(f)["project"]["dependencies"]
out = []
for d in deps:
    # Relax grpcio/grpcio_tools pins so pip can pick Python 3.13 wheels
    d2 = re.sub(r'^(grpcio(?:_tools)?)\s*~=\s*([\d.]+)', r'\1>=\2', d)
    out.append(d2)
print("\n".join(out))
EOF
)
# Install setuptools first so any sdist build steps find pkg_resources
"${PYTHON_BIN}" -m pip install --quiet --no-compile \
    --target="${mnt}/opt/python-deps" "setuptools"
echo "${DEPS}" | "${PYTHON_BIN}" -m pip install --quiet --no-compile \
    --target="${mnt}/opt/python-deps" -r /dev/stdin

# --- Python stdlib (interpreter needs this to do anything) ---
mkdir -p "${mnt}/usr/lib/${PYTHON_VER}"
cp -a "/usr/lib/${PYTHON_VER}/." "${mnt}/usr/lib/${PYTHON_VER}/" 2>/dev/null || true

# ============================================================================
# Stage 5 — ldd-resolve every binary, copy missing libs (multi-pass)
# ============================================================================
echo "[5/5] Resolving shared library dependencies..."
copy_ldd_for() {
  local bin=$1
  ldd "$bin" 2>/dev/null | awk '/=>/ {print $3}' | sort -u | while read -r lib; do
    [ -z "$lib" ] && continue
    [ ! -f "$lib" ] && continue
    local depname; depname=$(basename "$lib")
    local target
    if [[ "$lib" == */ceph/* ]]; then
      target="${mnt}/usr/lib64/ceph/${depname}"
    else
      target="${mnt}/usr/lib64/${depname}"
    fi
    [ -f "$target" ] || cp -L "$lib" "$target"
  done
}

# Pass 1: top-level binaries + everything we already staged
# Build the list via find so missing-glob errors are handled cleanly
mapfile -t TOP_BINS < <(
  for p in "${mnt}/usr/local/bin/nvmf_tgt" "${mnt}/usr/bin/ceph-nvmeof-monitor-client" "${mnt}/usr/bin/python3"; do
    [ -f "$p" ] && echo "$p"
  done
  find "${mnt}/usr/local/lib" "${mnt}${PYTHON_SITE}" "${mnt}/usr/lib64/rados-classes" \
       -maxdepth 1 -name '*.so*' -type f 2>/dev/null
)
for b in "${TOP_BINS[@]}"; do
  copy_ldd_for "$b"
done

# Recursive pass: keep ldd'ing newly-staged libs until stable
prev=-1
while :; do
  count=$(find "${mnt}/usr/lib64" "${mnt}/lib64" -name '*.so*' | wc -l)
  [ "$count" = "$prev" ] && break
  prev=$count
  while IFS= read -r lib; do
    copy_ldd_for "$lib"
  done < <(find "${mnt}/usr/lib64" "${mnt}/lib64" -name '*.so*' -type f 2>/dev/null)
done
echo "  staged $(find ${mnt}/usr/lib64 ${mnt}/lib64 -name '*.so*' | wc -l) shared libs"

# --- Minimal /etc that ldconfig/host-name-resolve/SSL need ---
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
# CA bundle so any future TLS work doesn't fail; harmless if unused
if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
  mkdir -p "${mnt}/etc/ssl/certs"
  cp /etc/ssl/certs/ca-certificates.crt "${mnt}/etc/ssl/certs/"
fi

# ============================================================================
# Image config + commit
# ============================================================================
buildah config \
  --port 5500/tcp --port 5501/tcp \
  --port 4420/tcp --port 4421/tcp \
  --port 8009/tcp --port 8010/tcp \
  --env "PYTHONPATH=/opt/python-deps:/opt/ceph-nvmeof:${PYTHON_SITE}" \
  --env "LD_LIBRARY_PATH=/usr/local/lib:/usr/lib64:/usr/lib64/ceph:/lib64" \
  --env "PATH=/usr/local/bin:/usr/bin" \
  --workingdir "/" \
  --entrypoint '["/usr/bin/python3","-m","control"]' \
  "$ctr"

buildah unmount "$ctr"
buildah commit "$ctr" "${IMAGE}"
buildah rm "$ctr"

echo
echo "=== Built: ${IMAGE} ==="
echo "Size: $(buildah images --format '{{.Size}}' "${IMAGE}")"
echo
echo "Push + import for k8s:"
echo "  buildah push ${IMAGE} \"oci-archive:/tmp/ceph-nvmeof.tar:${IMAGE}\""
echo "  ctr -n k8s.io images import /tmp/ceph-nvmeof.tar"
