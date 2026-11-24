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

## Operator runbook

Use this procedure to publish catalog changes. It is deliberately split into
source, signing, deployment and consumer verification: a source commit is not
public until all four stages complete.

### 1. Prepare the source commit

From a clean checkout of `main`, add or update application source directories
under `catalog/apps/`. Do **not** edit signed indexes, bundles or
`sources.json` by hand. Regenerate the human-readable catalog and validate the
editable sources:

```sh
mix catalog.docs
mix catalog.validate
mix precommit
git add catalog/apps catalog/CATALOG.md
git commit -m "Add latest catalog manifests"
git push origin main
```

`mix catalog.validate` may report new or edited applications as `pending`:
that is expected before the signing stage. `mix precommit` must pass before
pushing. Keep every new application as a **draft** unless its connection flow
has been reviewed and tested according to the root README.

### 2. Follow signing and deployment

Pushing `catalog/apps/**` to `main` starts both CI and Sign. With one
`manifests-ci` runner, Sign can be queued until CI frees it. The normal sequence
is:

1. CI validates the source commit.
2. Sign validates, signs the catalog, commits `Sign catalog: ...` to `main`,
   and dispatches CI because a `GITHUB_TOKEN` push does not trigger workflows.
3. CI passes for the signing commit.
4. Deploy builds the signed commit's image and, when `AUTO_DEPLOY=true`, rolls
   it out to `manifests.ragentic.io`.

Monitor the workflow runs for the source commit and the follow-up signing
commit. These commands are safe to run from the repository root:

```sh
gh run list --branch main --limit 12
gh run watch <source-ci-run-id> --exit-status
gh run watch <sign-run-id> --exit-status
gh run watch <deploy-run-id> --exit-status
```

Do not manually deploy an unsigned source commit. If automatic deployment is
disabled, wait for Sign and the follow-up CI to succeed, then intentionally
start the deploy workflow:

```sh
gh workflow run deploy.yml -f ref=main -f deploy=true
```

This command builds and rolls out the current signed `main`; it does not sign
catalog changes. To build without changing production, omit `-f deploy=true`.

### 3. Verify the public registry

After the deploy workflow succeeds, fetch both signed transports and verify an
expected application. Compare the local checkout only after pulling the signing
commit that the workflow created:

```sh
git pull --ff-only origin main
for file in index.json browse-index.json; do
  curl --fail --silent --show-error "https://manifests.ragentic.io/v1/$file" \
    | cmp - "catalog/$file"
done
curl --fail --silent --show-error \
  "https://manifests.ragentic.io/api/v1/manifests/<application-id>?version=latest" \
  >/dev/null
```

Draft entries belong in `browse-index.json`; published entries belong in
`index.json`. The deploy workflow performs an equivalent published-entry smoke
test and automatically undoes a rollout that does not become ready.

### 4. Verify GraphX

GraphX consumes this registry as the signed CatalogSource
`manifests.ragentic.io`, with the registry identity and root key pinned in
`catalog/registry.json`. Once the public checks pass:

1. Open `https://graphx.ragentic.io/catalog/registries` and confirm
   `manifests.ragentic.io` is healthy.
2. Browse or search the catalog for a newly deployed application id.
3. Open the definition and confirm its displayed version matches the signed
   bundle. Draft applications are discoverable but cannot be connected;
   published applications offer the connection flow.

If a new entry is absent, first compare the public signed index above. If the
index contains it, refresh the GraphX catalog view and inspect the CatalogSource
status; do not weaken its pinned key, identity, or minimum sequence to bypass
signature verification.

### Failure guide

| Stage | What it means | Next action |
| --- | --- | --- |
| CI fails | Source or generated docs are invalid. | Fix the reported source files, rerun the preparation checks, then push a new commit. |
| Sign fails | The signing environment, pinned root, or strict signed validation failed. | Inspect the Sign logs; never create local substitute signatures or edit generated signed files. |
| Deploy fails | The rollout or public signed-index smoke check failed. | The script rolls back automatically. Inspect deploy logs and cluster events, fix the cause, then rerun the signed deploy. |
| GraphX cannot browse an entry | The registry is not yet serving the signed entry or the consumer needs a refresh. | Verify the public index first, then refresh/check the signed CatalogSource. |

## History

The image only carries the current catalog. Older signed versions come from
git history (`Manifests.Catalog.backfill/2`, run locally into `manifests_dev`)
and are copied in with:

    docker exec ragentic-test-pg pg_dump -U postgres -d manifests_dev --data-only \
      --inserts --on-conflict-do-nothing -t manifests -t manifest_versions -t catalog_snapshots \
      | kubectl -n manifests exec -i postgres-0 -- psql -q -U manifests -d manifests

## CI runners

`k8s/ci-runners.yaml` registers two GitHub Actions runner scale sets for this
repository on the cluster's actions-runner-controller (the controller, the
`arc-github` token secret and the Harbor push credentials come from ragentic's
`k8s/ci/runner.yaml`):

- `manifests-ci`: CI, Sign and the image build. Same runner image and limits
  as `ragentic-ci`, one runner, never on k3s-1.
- `manifests-deploy`: rolls `deploy/manifests` onto a Harbor digest as service
  account `arc-runners/manifests-deployer`, which may only patch that
  Deployment and read pods, logs and events in namespace `manifests`: no
  Secrets, not the Postgres StatefulSet, nothing in other namespaces.

Both scale from zero. Workflows select them with `runs-on: manifests-ci` or
`runs-on: manifests-deploy`. To install:

1. Let the `arc-github` token register runners on ragentic-io/manifests: add
   the repo to the fine-grained PAT, or use a classic PAT with `repo`.
2. `kubectl apply -f deploy/k8s/ci-runners.yaml`
3. `kubectl auth can-i --as system:serviceaccount:arc-runners:manifests-deployer patch deploy/manifests -n manifests`
   says yes; the same with `get secrets` says no.

An organization-level `githubConfigUrl` (`https://github.com/ragentic-io`)
would let `ragentic-ci` serve both repositories instead, but needs a token with
`admin:org`.

## Checks

    for f in index.json browse-index.json; do curl -s https://manifests.ragentic.io/v1/$f | cmp - catalog/$f; done
    curl -s -o /dev/null -w '%{http_code}\n' https://manifests.ragentic.io/api/v1/manifests/stripe-openapi   # 400
