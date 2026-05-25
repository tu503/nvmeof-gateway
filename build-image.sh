#!/bin/bash
# build-image.sh — Build a ceph-nvmeof gateway OCI image from host binaries.
#
# Bundles:
#   - SPDK target daemon (`/usr/bin/nvmf_tgt` from dev-libs/spdk, pulled in
#     by sys-cluster/ceph USE="spdk").
#   - librbd / librados / ceph python bindings from sys-cluster/ceph.
#   - Upstream ceph-nvmeof control plane (Python; pinned tag) installed via
#     `pip install --target=<staging>`.
#   - All ldd-resolved shared library deps.
#
# Mirrors the rgw-gateway/build-image.sh pattern (host binaries → scratch
# base via buildah) but with a Python staging step for the upstream gateway
# code that Gentoo doesn't package.
#
# Usage: ./build-image.sh [tag]
# Example: ./build-image.sh v20.1.1
#
# Pin: upstream ceph-nvmeof tag tracks Ceph minor (tentacle → 1.6.x).

set -euo pipefail

# ------------------------------------------------------------------ config
CEPH_VERSION=$(ceph --version | awk '{print $3}')
NVMEOF_TAG=${NVMEOF_TAG:-1.6.14}                                 # tentacle_9.1_v1.6.14
TAG="${1:-v${CEPH_VERSION}}"
IMAGE="registry.alcg.io/ceph-nvmeof:${TAG}"

# Host artifacts we depend on. Resolved at runtime.
SPDK_BIN=$(command -v nvmf_tgt || echo "/usr/bin/nvmf_tgt")
SPDK_RPC=$(command -v spdk_rpc.py || echo "/usr/libexec/spdk/scripts/rpc.py")
PYTHON_BIN=$(command -v python3)
PYTHON_VER=$("${PYTHON_BIN}" -c 'import sys; print(f"python{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_SITE="/usr/lib/${PYTHON_VER}/site-packages"

echo "=== Building ceph-nvmeof image: ${IMAGE} ==="
echo "  ceph_version  = ${CEPH_VERSION}"
echo "  nvmeof_tag    = ${NVMEOF_TAG}  (upstream pin)"
echo "  spdk_bin      = ${SPDK_BIN}"
echo "  spdk_rpc      = ${SPDK_RPC}"
echo "  python        = ${PYTHON_BIN}  (${PYTHON_VER})"
echo

# ------------------------------------------------------------------ stage upstream ceph-nvmeof
NVMEOF_STAGING=$(mktemp -d -t nvmeof-stage-XXXX)
trap 'rm -rf "${NVMEOF_STAGING}"' EXIT

echo "Fetching ceph-nvmeof ${NVMEOF_TAG} into ${NVMEOF_STAGING}..."
git clone --depth 1 --branch "${NVMEOF_TAG}" \
    https://github.com/ceph/ceph-nvmeof.git "${NVMEOF_STAGING}/ceph-nvmeof"

# Generate the gRPC protobuf python bindings.
# Upstream's Makefile does this; we do it explicitly so we can stage offline.
(
  cd "${NVMEOF_STAGING}/ceph-nvmeof"
  "${PYTHON_BIN}" -m grpc_tools.protoc \
      -I control/proto \
      --python_out=control/proto \
      --grpc_python_out=control/proto \
      control/proto/gateway.proto
)

# ------------------------------------------------------------------ container assembly
ctr=$(buildah from scratch)
mnt=$(buildah mount "$ctr")

mkdir -p \
    "${mnt}/usr/bin" \
    "${mnt}/usr/local/bin" \
    "${mnt}/usr/lib64/ceph" \
    "${mnt}/lib64" \
    "${mnt}/etc" \
    "${mnt}/var/tmp" \
    "${mnt}/dev/hugepages" \
    "${mnt}${PYTHON_SITE}" \
    "${mnt}/opt/ceph-nvmeof/control" \
    "${mnt}/opt/ceph-nvmeof/control/proto"

# ------------------------------------------------------------------ binaries
echo "Copying SPDK target + helpers..."
cp "${SPDK_BIN}"      "${mnt}/usr/local/bin/nvmf_tgt"
cp "${SPDK_RPC}"      "${mnt}/usr/local/bin/spdk_rpc.py" 2>/dev/null || true

echo "Copying python interpreter..."
cp "${PYTHON_BIN}"    "${mnt}/usr/bin/python3"

echo "Copying ld-linux..."
cp /lib64/ld-linux-x86-64.so.2 "${mnt}/lib64/"

# ------------------------------------------------------------------ python control plane
echo "Staging ceph-nvmeof control plane..."
cp -r "${NVMEOF_STAGING}/ceph-nvmeof/control"/* "${mnt}/opt/ceph-nvmeof/control/"
# Also need to symlink so `python3 -m control` works from /
ln -sfT /opt/ceph-nvmeof/control "${mnt}/control"

# ------------------------------------------------------------------ python deps
echo "Pip-installing ceph-nvmeof python deps..."
"${PYTHON_BIN}" -m pip install --no-compile --target="${mnt}/opt/python-deps" \
    -r "${NVMEOF_STAGING}/ceph-nvmeof/requirements.txt"

# Also bring the host's rados/rbd python bindings (compiled .so against host libs)
cp "${PYTHON_SITE}/rados".*.so "${mnt}${PYTHON_SITE}/"
cp "${PYTHON_SITE}/rbd".*.so   "${mnt}${PYTHON_SITE}/"

# ------------------------------------------------------------------ ldd-resolved libs (multi-pass)
copy_ldd() {
  local bin=$1
  ldd "$bin" 2>/dev/null | grep "=>" | awk '{print $3}' | sort -u | while read -r lib; do
    [ -z "$lib" ] && continue
    [ ! -f "$lib" ] && continue
    local depname; depname=$(basename "$lib")
    local target
    if [[ "$lib" == */ceph/* ]]; then
      target="${mnt}/usr/lib64/ceph/${depname}"
    elif [[ "$lib" == */gcc/* ]]; then
      target="${mnt}/usr/lib64/${depname}"
    else
      target="${mnt}/usr/lib64/${depname}"
    fi
    [ -f "$target" ] || cp "$lib" "$target"
  done
}

echo "Copying shared libraries (first pass: top-level binaries)..."
for b in "${mnt}/usr/local/bin/nvmf_tgt" "${mnt}/usr/bin/python3" \
         "${mnt}${PYTHON_SITE}/rados".*.so "${mnt}${PYTHON_SITE}/rbd".*.so; do
  [ -f "$b" ] && copy_ldd "$b"
done

echo "Resolving secondary dependencies (recurse until stable)..."
found_new=true
while $found_new; do
  found_new=false
  for lib in "${mnt}"/usr/lib64/*.so* "${mnt}"/usr/lib64/ceph/*.so* "${mnt}"/lib64/*.so*; do
    [ -f "$lib" ] || continue
    while read -r dep; do
      [ -z "$dep" ] && continue
      [ ! -f "$dep" ] && continue
      local depname; depname=$(basename "$dep")
      if [ ! -f "${mnt}/usr/lib64/${depname}" ] && \
         [ ! -f "${mnt}/usr/lib64/ceph/${depname}" ] && \
         [ ! -f "${mnt}/lib64/${depname}" ]; then
        if [[ "$dep" == */ceph/* ]]; then
          cp "$dep" "${mnt}/usr/lib64/ceph/"
        else
          cp "$dep" "${mnt}/usr/lib64/"
        fi
        echo "  + ${depname}"
        found_new=true
      fi
    done < <(ldd "$lib" 2>/dev/null | grep "=>" | awk '{print $3}' | sort -u)
  done
done

# ------------------------------------------------------------------ python stdlib
# Bring the host's python stdlib so the interpreter can run.
echo "Staging python stdlib..."
mkdir -p "${mnt}/usr/lib/${PYTHON_VER}"
cp -r "/usr/lib/${PYTHON_VER}"/* "${mnt}/usr/lib/${PYTHON_VER}/" 2>/dev/null || true

# ------------------------------------------------------------------ minimal /etc
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

# A trivial /bin/sh implementation: busybox-style fallback is overkill — the
# pod's `command: ["/bin/sh","-c"]` is supplied via a separate alpine sidecar
# or via the upstream container's already-baked bash. For the scratch path
# here, we wire the entrypoint directly to python and rely on the deployment
# spec to drive ceph-nvmeof.conf rendering via initContainer instead of /bin/sh.
# (See the README's "scratch-base notes" section.)

# ------------------------------------------------------------------ runtime env
buildah config \
  --port 5500/tcp \
  --port 4420/tcp \
  --port 8009/tcp \
  --env "PYTHONPATH=/opt/python-deps:/opt/ceph-nvmeof:${PYTHON_SITE}" \
  --env "LD_LIBRARY_PATH=/usr/lib64:/usr/lib64/ceph:/lib64" \
  --entrypoint '["/usr/bin/python3","-m","control"]' \
  "$ctr"

# ------------------------------------------------------------------ commit + push
buildah unmount "$ctr"
buildah commit "$ctr" "${IMAGE}"
buildah rm "$ctr"

echo
echo "=== Built: ${IMAGE} ==="
echo "Size: $(buildah images --format '{{.Size}}' "${IMAGE}")"
echo
echo "Push + import for k8s:"
echo "  buildah push ${IMAGE} oci-archive:/tmp/ceph-nvmeof.tar"
echo "  ctr -n k8s.io images import /tmp/ceph-nvmeof.tar --tag ${IMAGE}"
