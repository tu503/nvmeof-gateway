# Self-referential flux wiring

These two manifests bootstrap Flux to watch this repo. Apply **once**, by
hand — after that, every commit to `main` reconciles automatically and
this directory itself reconciles too (so future edits to `flux/*.yaml`
take effect on next push, not on a redo of the bootstrap).

## Prereqs

1. A GitLab deploy key with `read_repository` scope on `homelab/infra/nvmeof-gateway`.
2. The matching private key materialized as a Secret in the `flux-system` namespace named `nvmeof-gateway-git-ssh`, with keys `identity`, `identity.pub`, and `known_hosts`.

Bootstrap commands (run from this repo root):

```sh
# 1. Apply the namespace + flux wiring (Kustomization will pull deploy/
#    on the next reconcile cycle and bring up the gateway pods).
kubectl apply -f 00-namespace.yaml
kubectl apply -f flux/source.yaml -f flux/kustomization.yaml

# 2. Force an immediate reconcile (optional — happens on the 1-min cycle anyway)
flux reconcile source git -n flux-system nvmeof-gateway
flux reconcile kustomization -n flux-system nvmeof-gateway
```

After this, `git push` to `main` is the deployment mechanism.

## Why self-referential?

Other homelab projects centralize their `flux-<app>.yaml` files in
`homelab/infra/gitlab`. Bundling the wiring inside the app's own repo
keeps each gateway's "what flux needs to track me" definition next to
the manifests being tracked. Trade-off: the bootstrap is a one-time
manual apply rather than a single-PR-to-gitlab-repo flow.
