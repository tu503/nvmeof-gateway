# homelab/infra/nvmeof-gateway — Ceph RBD via NVMe-oF/TCP

Two `ceph-nvmeof` gateway pods on sm3, sharing one **ANA group**
(`rbd-default`), exposing RBD images as NVMe-oF/TCP namespaces to clients
that don't have any Ceph software installed. Initiators see two paths
(VIPs `10.144.27.224` and `.225`) and fail over automatically when a
gateway pod dies.

This is the block-device analogue of `homelab/infra/rgw-gateway` (S3) —
same Ceph cluster, same custom-built-from-host pattern, but for the
NVMe-oF data path.

## Architecture

```mermaid
flowchart LR
    subgraph cluster[homelab cluster — ns nvmeof-gateway, node sm3]
      GW_A[nvmeof-gw-a Deployment x1<br/>SPDK + librbd<br/>:4420 nvme-tcp, :5500 gRPC]
      GW_B[nvmeof-gw-b Deployment x1<br/>SPDK + librbd<br/>:4420 nvme-tcp, :5500 gRPC]
      SVC_A[Service nvmeof-gw-a<br/>LB 10.144.27.224]
      SVC_B[Service nvmeof-gw-b<br/>LB 10.144.27.225]
    end
    subgraph rados[Ceph RADOS]
      STATE[(pool nvmeof<br/>replicated, omap<br/>gateway state)]
      DATA[(pool nvmeof-data<br/>EC k=6 m=3<br/>RBD payload)]
      RBD[(pool rbd<br/>replicated<br/>RBD metadata)]
    end
    subgraph mon[ceph-mon (USE=nvmeof spdk)]
      ANA[NVMeofGwMon<br/>ANA state coordination]
    end
    SVC_A --> GW_A
    SVC_B --> GW_B
    GW_A -. beacon .-> ANA
    GW_B -. beacon .-> ANA
    GW_A --> RBD & DATA & STATE
    GW_B --> RBD & DATA & STATE
    EXT[External initiator<br/>nvme-cli, no Ceph software] -->|nvme connect --multipath<br/>tcp:224+225| SVC_A
    EXT --> SVC_B
```

The mon-side `NVMeofGwMon` Paxos service is what makes ANA work: it owns
which gateway is the **Optimized** path for each namespace, drives
failover when a gateway stops beaconing, and exposes `ceph nvmeof gw ls`.
That code is gated by `sys-cluster/ceph USE="nvmeof spdk"` — make sure
both flags are on (homelab overlay's `package.use/ceph` covers it).

## Layout

```
00-namespace.yaml                  ns nvmeof-gateway
deploy/
├── 10-ceph-config.yaml            ConfigMap ceph-config-nvmeof — global + per-client sections
├── 15-nvmeof-config.yaml          ConfigMap nvmeof-gateway-config — ceph-nvmeof.conf.tmpl
├── 11-keyring-gw-a.sealed.yaml    SealedSecret ceph-nvmeof-keyring-gw-a
├── 11-keyring-gw-b.sealed.yaml    SealedSecret ceph-nvmeof-keyring-gw-b
├── 20-deployment-gw-a.yaml        Deployment nvmeof-gw-a (sm3-pinned, hugepages, privileged)
├── 20-deployment-gw-b.yaml        Deployment nvmeof-gw-b
├── 30-service-gw-a.yaml           LoadBalancer 10.144.27.224 (ports 4420/5500/8009)
├── 30-service-gw-b.yaml           LoadBalancer 10.144.27.225
└── kustomization.yaml             entry point reconciled by flux

setup-group.sh                     idempotent: pools + ec-profile + cephx clients +
                                     `ceph nvmeof gw group create` + kubeseal both keyrings

build-image.sh                     Build registry.alcg.io/ceph-nvmeof:<tag> from host
                                     SPDK + librbd + upstream ceph-nvmeof python control

flux/
├── source.yaml                    GitRepository nvmeof-gateway → this repo
├── kustomization.yaml             Kustomization → ./deploy/
└── README.md                      one-time bootstrap instructions
```

## Pools

| Pool          | Type                 | Used for                              |
| ------------- | -------------------- | ------------------------------------- |
| `nvmeof`      | replicated, 32 PGs   | gateway state (RADOS omap; EC unsafe) |
| `nvmeof-data` | EC k=6 m=3, 32 PGs   | RBD data via `--data-pool nvmeof-data`|
| `rbd`         | (existing)           | RBD metadata + non-data-pool images   |

Create demo images that use the EC data pool:

```sh
rbd create rbd/demo-nvmeof --size 5G --data-pool nvmeof-data --image-feature layering,exclusive-lock,object-map,fast-diff,deep-flatten
```

## Caps on `client.nvmeof.gw-{a,b}`

```
mon  "profile rbd"
mgr  "profile rbd"
osd  "profile rbd pool=nvmeof, profile rbd pool=nvmeof-data, profile rbd pool=rbd"
```

`profile rbd` is the standard RBD client cap — narrowly scoped to the
pools we care about. (Note: `profile rgw` is broken on tentacle 20.1.1
here; `profile rbd` does not have the same regression. See memory
`feedback_ceph_tentacle_rgw_caps.md` for the gory details.)

## First-time bring-up

```sh
# 1. Verify ceph-mon was built with USE="nvmeof spdk" (one-time, on sm3)
ceph nvmeof gw ls           # should return [], not "unknown command"

# 2. Provision pools + cephx clients + gateway group + sealed yamls
./setup-group.sh

# 3. Build the gateway container, push, and import into the k8s containerd ns
./build-image.sh v20.1.1
buildah push registry.alcg.io/ceph-nvmeof:v20.1.1 oci-archive:/tmp/ceph-nvmeof.tar
ctr -n k8s.io images import /tmp/ceph-nvmeof.tar --tag registry.alcg.io/ceph-nvmeof:v20.1.1

# 4. Bootstrap flux (see flux/README.md for deploy-key prereqs)
kubectl apply -f 00-namespace.yaml
kubectl apply -f flux/source.yaml -f flux/kustomization.yaml
```

After step 4, any change to `main` is reconciled automatically. Includes
this `flux/` directory — so you can iterate on the flux wiring itself
without re-bootstrapping.

## Adding a subsystem / namespace

```sh
GW_NQN=nqn.2026-05.io.alcg:demo
nvmeof-cli --server-address 10.144.27.224 --server-port 5500 \
  subsystem add --subsystem "$GW_NQN" --max-namespaces 32
nvmeof-cli --server-address 10.144.27.224 --server-port 5500 \
  namespace add --subsystem "$GW_NQN" --rbd-pool rbd --rbd-image demo-nvmeof
nvmeof-cli --server-address 10.144.27.224 --server-port 5500 \
  listener add --subsystem "$GW_NQN" --gateway-name gw-a --traddr 10.144.27.224 --trsvcid 4420
nvmeof-cli --server-address 10.144.27.225 --server-port 5500 \
  listener add --subsystem "$GW_NQN" --gateway-name gw-b --traddr 10.144.27.225 --trsvcid 4420
nvmeof-cli --server-address 10.144.27.224 --server-port 5500 \
  host add --subsystem "$GW_NQN" --host-nqn "*"
```

Both listeners — that's the ANA pair. The mon will mark one Optimized
and the other Non-Optimized; initiators with `nvme connect --multipath`
will use both.

## Initiator side (any Linux box, no Ceph install needed)

```sh
modprobe nvme-tcp
nvme discover -t tcp -a 10.144.27.224 -s 8009
nvme connect-all --transport tcp \
    -a 10.144.27.224 -s 4420 \
    --hostnqn=nqn.2014-08.org.nvmexpress:uuid:$(uuidgen)
lsblk                                  # /dev/nvme0n1 appears
```

## ANA failover smoke test

```sh
fio --name=fail --rw=randrw --bs=4k --iodepth=8 --numjobs=2 \
    --size=1G --time_based --runtime=120 --ioengine=libaio --direct=1 \
    --filename=/dev/nvme0n1 &

kubectl -n nvmeof-gateway delete pod -l gateway=gw-a
# fio should see a brief latency spike but no errors.

wait
```

## Caveats

- **Single-host placement.** Both gateways are pinned to sm3 by
  `nodeSelector`. If sm3 goes down the data path stops. For multi-host
  HA you'd need a second sm3-class node with hugepages allocated and a
  second MetalLB advertisement; not in scope for the homelab.
- **HugePages on the host.** `vm.nr_hugepages=2048` (4 GiB of 2 MiB
  pages) is set via `/etc/sysctl.d/50-hugepages-nvmeof.conf`. If you
  ever roll back the gateway, also roll that back to free the memory.
- **SPDK CPU pinning.** Not configured here; both gateway pods get a
  generous `cpu: 2` limit. If you start running ceph-nvmeof for real
  load, look at SPDK reactor pinning + Kubernetes static CPU manager.
- **Container build is host-dependent.** `build-image.sh` runs `ldd`
  against host binaries — the resulting image is only guaranteed to
  work on hosts running matching Ceph + SPDK versions.

## TODO

- Promote `nvmeof-cli` invocations from the README into a
  `setup-subsystem.sh` script (mirrors `rgw-gateway/setup-instance.sh`).
- Add a Grafana dashboard panel for the nvmeof gateway's SPDK stats.
- Consider mTLS on the gRPC control plane (currently `enable_auth = False`).
- Wire image-update-automation when the upstream tag bumps.
