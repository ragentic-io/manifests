# Deploying manifests.ragentic.io

Runs on the homelab k3s cluster (namespace `manifests`). The image bakes in the
signed catalog (`catalog/` indexes, bundles and `MANIFEST.md` files); the app
verifies and imports it into Postgres on boot. A merge to `main` deploys itself
(Pipeline); the hand procedure after it is the fallback.

## Pipeline

```
pull request ──► CI (ci.yml): format, compile --warnings-as-errors, mix test, mix catalog.validate

merge to main ─┬─► CI ──► deploy (deploy.yml)
               │            build  ghcr.io/ragentic-io/ragentic-manifests:main-<sha12>
               │                   CATALOG_COMMIT = last commit of catalog/index.json
               │            deploy (runner "manifests-deploy" in k3s), scripts/deploy.sh:
               │                   crane copy → harbor.home/library/ragentic-manifests:main-<sha12>
               │                   set image migrate + registry to tag@digest
               │                   rollout status → undo if it fails
               │                   /v1/index.json = catalog/index.json, stripe-openapi@latest 200
               └─► Sign (sign.yml), when catalog/apps, registry.json or the tools changed:
                     validate → sign → validate --require-signed
                     → commit "Sign catalog: …" to main → dispatch CI ──► deploy
```

- **Workflows:** `.github/workflows/ci.yml`, `sign.yml`, `deploy.yml`. CI, Sign
  and the image build run on `manifests-ci`, the deploy on `manifests-deploy`:
  ARC scale sets registered to this repository in ragentic's
  `k8s/ci/runner.yaml` (one runner each, gone after the job).
- **Signing stays in the `registry-signing` environment** (catalog/README.md
  "Signing"). A push with the workflow token starts no workflow, so Sign
  dispatches CI for its commit; CI's success on `main` (push or that dispatch)
  is what starts deploy. The daily re-sign deploys the same way. A merge that
  changes an application deploys twice: once with the old index, then the
  signed one.
- **The switch:** the deploy job runs only while the repository variable
  `AUTO_DEPLOY` is `true`. Without it `main` is still checked and built.
  By hand: `gh workflow run deploy.yml -f ref=main -f deploy=true`.
- **Pinned by digest, never `:latest`:** `kubectl -n manifests rollout history
  deploy/manifests` and the `kubernetes.io/change-cause` annotation name the
  commit.
- **Failure:** a rollout not ready in 10 minutes prints the pods' logs and
  events and is undone; the old pod keeps serving (`maxUnavailable: 0`). The
  run fails red, as it does when the public index is not this commit's.
- **The runner's rights:** service account `arc-runners/manifests-deployer`
  may patch `deploy/manifests` and read pods, logs and events in namespace
  `manifests`, nothing else: no Secrets, no other namespace. Changes to
  `deploy/k8s/manifests.yaml` other than the image (env, probes, Postgres) are
  still applied by hand, as below, with the image the pipeline last deployed:

      IMG=$(kubectl -n manifests get deploy manifests -o jsonpath='{.spec.template.spec.containers[0].image}')
      sed "s|harbor.home/library/ragentic-manifests:IMAGE_TAG|$IMG|" deploy/k8s/manifests.yaml | kubectl apply -f -

## Build and push (by hand)

    C=$(git log -1 --format=%H -- catalog/index.json)
    T=$(git rev-parse --short HEAD)-$(date +%Y%m%d%H%M)
    docker build --build-arg CATALOG_COMMIT=$C -t harbor.home/library/ragentic-manifests:$T .
    docker push harbor.home/library/ragentic-manifests:$T   # or ~/Work/ragentic/scripts/push-image.sh

The repo must not be named `manifests`: Harbor routes
`/v2/library/manifests/blobs/...` as a manifest request and every push 400s.
Never push `:latest`; deploy by tag@digest.

## Secret (first deploy only)

    PW=$(openssl rand -hex 24)
    kubectl create namespace manifests
    kubectl -n manifests create secret generic manifests-secrets \
      --from-literal=POSTGRES_PASSWORD="$PW" \
      --from-literal=DATABASE_URL="ecto://manifests:$PW@postgres-0.postgres.manifests.svc.cluster.local/manifests" \
      --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')"

## Apply

    IMG="$T@sha256:<digest from the push>"
    sed "s|IMAGE_TAG|$IMG|" deploy/k8s/manifests.yaml | kubectl apply -f -
    kubectl -n manifests rollout status deploy/manifests

The init container runs migrations. Readiness is `/v1/index.json`, which turns
200 once the published index is imported; the drafts (browse index) finish
importing about a minute later, so draft app pages 404 to the search page
until then.

## History

The image only carries the current catalog. Older signed versions come from
git history (`Manifests.Catalog.backfill/2`, run locally into `manifests_dev`)
and are copied in with:

    docker exec ragentic-test-pg pg_dump -U postgres -d manifests_dev --data-only \
      --inserts --on-conflict-do-nothing -t manifests -t manifest_versions -t catalog_snapshots \
      | kubectl -n manifests exec -i postgres-0 -- psql -q -U manifests -d manifests

## Checks

    for f in index.json browse-index.json; do curl -s https://manifests.ragentic.io/v1/$f | cmp - catalog/$f; done
    curl -s -o /dev/null -w '%{http_code}\n' https://manifests.ragentic.io/api/v1/manifests/stripe-openapi   # 400
