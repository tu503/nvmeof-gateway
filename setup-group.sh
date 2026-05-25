#!/bin/bash
# Idempotent: provisions Ceph state needed for the nvmeof-gateway ANA group.
# Safe to re-run — every step checks for existing resources first.
#
# Outputs:
#   - pool         "nvmeof"        (replicated, app=nvmeof, gateway state via omap)
#   - pool         "nvmeof-data"   (EC k=6 m=3, app=nvmeof, RBD data payload)
#   - cephx client "client.nvmeof.gw-a" and ".gw-b" with `profile rbd` caps
#   - gateway-group "rbd-default" registered with mon
#   - deploy/11-keyring-gw-{a,b}.sealed.yaml piped through kubeseal
#
# Re-run anytime you change caps, rotate keys, or add a gateway.

set -euo pipefail

GROUP_NAME=${GROUP_NAME:-rbd-default}
POOL_STATE=${POOL_STATE:-nvmeof}
POOL_DATA=${POOL_DATA:-nvmeof-data}
EC_PROFILE=${EC_PROFILE:-ec-6-3-profile}
NAMESPACE=${NAMESPACE:-nvmeof-gateway}
GATEWAYS=(gw-a gw-b)

repo_dir=$(dirname "$(readlink -f "$0")")
mkdir -p "${repo_dir}/deploy"

ensure_pool_replicated() {
  local name=$1 pgs=$2
  if ceph osd pool ls 2>/dev/null | grep -qx "${name}"; then
    echo "[=] pool ${name} already exists"
  else
    ceph osd pool create "${name}" "${pgs}" "${pgs}" replicated
    echo "[+] created replicated pool ${name}"
  fi
  ceph osd pool application enable "${name}" nvmeof --yes-i-really-mean-it >/dev/null 2>&1 || true
}

ensure_ec_profile() {
  local name=$1
  if ceph osd erasure-code-profile ls 2>/dev/null | grep -qx "${name}"; then
    echo "[=] erasure-code-profile ${name} already exists"
  else
    ceph osd erasure-code-profile set "${name}" \
        k=6 m=3 \
        crush-failure-domain=osd \
        plugin=jerasure technique=reed_sol_van
    echo "[+] created erasure-code-profile ${name}"
  fi
}

ensure_pool_ec() {
  local name=$1 pgs=$2 profile=$3
  if ceph osd pool ls 2>/dev/null | grep -qx "${name}"; then
    echo "[=] pool ${name} already exists"
  else
    ceph osd pool create "${name}" "${pgs}" "${pgs}" erasure "${profile}"
    ceph osd pool set "${name}" allow_ec_overwrites true
    echo "[+] created EC pool ${name} (profile=${profile}, allow_ec_overwrites=true)"
  fi
  ceph osd pool application enable "${name}" nvmeof --yes-i-really-mean-it >/dev/null 2>&1 || true
}

ensure_cephx_client() {
  local id=$1
  local entity="client.nvmeof.${id}"
  local key
  if ceph auth get "${entity}" &>/dev/null; then
    key=$(ceph auth get-key "${entity}")
    echo "[=] cephx ${entity} already exists" >&2
    ceph auth caps "${entity}" \
        mon "profile rbd" \
        osd "profile rbd pool=${POOL_STATE}, profile rbd pool=${POOL_DATA}, profile rbd pool=rbd" \
        mgr "profile rbd" >/dev/null
  else
    ceph auth get-or-create "${entity}" \
        mon "profile rbd" \
        osd "profile rbd pool=${POOL_STATE}, profile rbd pool=${POOL_DATA}, profile rbd pool=rbd" \
        mgr "profile rbd" >/dev/null
    key=$(ceph auth get-key "${entity}")
    echo "[+] created cephx ${entity}" >&2
  fi
  # Only the key bytes go to stdout — caller captures via $(...)
  printf '%s' "${key}"
}

seal_keyring() {
  local id=$1 key=$2
  local entity="client.nvmeof.${id}"
  local out="${repo_dir}/deploy/11-keyring-${id}.sealed.yaml"
  if ! command -v kubeseal >/dev/null; then
    echo "ERROR: kubeseal not in PATH" >&2; exit 1
  fi
  cat <<EOF | kubeseal \
      --controller-namespace kube-system \
      --controller-name sealed-secrets-controller \
      --format yaml > "${out}"
apiVersion: v1
kind: Secret
metadata:
  name: ceph-nvmeof-keyring-${id}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  keyring: |
    [${entity}]
    key = ${key}
EOF
  echo "[+] wrote ${out}"
}

ensure_gw_registered() {
  local id=$1 pool=$2 group=$3
  # `ceph nvme-gw show <pool> <group>` lists current members; create if absent.
  if ceph nvme-gw show "${pool}" "${group}" 2>/dev/null | grep -q "\"${id}\""; then
    echo "[=] gateway ${id} already registered in (${pool}, ${group})"
  else
    ceph nvme-gw create "${id}" "${pool}" "${group}" || \
        { echo "ERROR: ceph nvme-gw create failed — is sys-cluster/ceph built with USE=\"nvmeof spdk\"?"; exit 1; }
    echo "[+] registered gateway ${id} in (${pool}, ${group})"
  fi
}

main() {
  echo "=== State pool (replicated, omap) ==="
  ensure_pool_replicated "${POOL_STATE}" 32

  echo "=== Data pool (EC 6+3, RBD payload) ==="
  ensure_ec_profile "${EC_PROFILE}"
  ensure_pool_ec "${POOL_DATA}" 32 "${EC_PROFILE}"

  echo "=== Cephx clients + sealed keyrings ==="
  for gw in "${GATEWAYS[@]}"; do
    key=$(ensure_cephx_client "${gw}")
    seal_keyring "${gw}" "${key}"
  done

  echo "=== Register each gateway in the ANA group ==="
  for gw in "${GATEWAYS[@]}"; do
    ensure_gw_registered "${gw}" "${POOL_STATE}" "${GROUP_NAME}"
  done

  echo
  echo "Done. Sealed keyrings under deploy/. Re-run anytime — idempotent."
}

main "$@"
