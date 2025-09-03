# mTLS Service Mesh (Linkerd)

This repository now includes a **Linkerd**-based service mesh with **automatic mTLS** and a default-**require-authenticated** inbound policy for all meshed pods.

## What this adds

- Linkerd control plane installed via **Helm** (repeatable, no manual kubectl).
- **mTLS by default**: we set `policyController.defaultAllowPolicy=all-authenticated`, so inbound traffic to meshed pods **must** be mTLS from another meshed pod.
- Namespaces `pingpong-a` and `pingpong-b` are **auto-injected** with the Linkerd proxy and annotated to require authenticated inbound.
- Make targets to bring the mesh **up/down**, **inject** namespaces, and **test** quickly.

> Certificates for Linkerd identity are generated locally via OpenSSL under `infra/mesh/certs/` (git-ignored).
> For production, consider using **cert-manager + trust-manager** for rotation.

## Quick start

```bash
# 0) cluster + app (from root)
make platform-up

# 1) bring up Linkerd service mesh with mTLS enforced
make mesh-up

# 2) inject proxies + require mTLS inbound
make mesh-apply

# 3) validate sidecars present
make mesh-status

# 4) (optional) test unauthenticated access is denied
make mesh-test
```

## What the targets do

- **`mesh-up`**
  - Adds Linkerd Helm repo and installs `linkerd-crds` and `linkerd-control-plane` to the `linkerd` namespace.
  - Generates `infra/mesh/certs/ca.crt`, `issuer.crt`, `issuer.key` and passes them to Helm.
  - Sets default policy to **all-authenticated** (require mTLS).

- **`mesh-apply`**
  - Annotates `pingpong-a` and `pingpong-b` with:
    - `linkerd.io/inject=enabled`
    - `config.linkerd.io/default-inbound-policy=all-authenticated`
  - Restarts deployments so proxies are injected.

- **`mesh-test`**
  - Launches a non-meshed curl pod in `default` namespace and attempts to call services.
  - Expected: HTTP **403** / connection refused due to policy (not mTLS).

- **`mesh-down`**
  - Uninstalls Linkerd and cleans the `linkerd` namespace.

## Verifying mTLS

Even without the Linkerd CLI, you can see the proxy sidecar:

```bash
kubectl -n pingpong-a get pods -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
```

Each pod should show a `linkerd-proxy` container alongside the app container.

If you have the Linkerd CLI installed, additional checks:

```bash
linkerd check
linkerd viz tap -n pingpong-a deploy/pingpong-a
```

## Production notes

- Prefer **cert-manager** + **trust-manager** to automate issuer and trust bundle rotation.
- Switch the default policy to `deny` and write explicit `Server` / `ServerAuthorization` resources per port/workload for a stricter zero-trust stance.
- Run the Linkerd control plane in **HA** mode to enforce proxy presence during pod startup.

---

## Automating certs with cert-manager + trust-manager (no manual OpenSSL)

The repo includes Kubernetes manifests to **generate/rotate** Linkerd certificates using cert-manager and to **propagate** the trust anchor using trust-manager.

```bash
# Install cert-manager and trust-manager via Helm
make mesh-prereqs

# Create trust anchor + identity issuer with cert-manager and wait for Secrets
make mesh-bootstrap-ca

# Install Linkerd using the certs fetched from those Secrets (mTLS enforced)
make mesh-up
```

This way, cert-manager rotates the identity issuer before expiry; you can run `make mesh-up` again to roll the new certs into the Linkerd deployment.
