# Deploying manifests.ragentic.io

Hand-deployed to the homelab k3s cluster (namespace `manifests`). The image
bakes in the signed catalog (`catalog/` indexes, bundles and `MANIFEST.md`
files); the app verifies and imports it into Postgres on boot.

## Build and push

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
