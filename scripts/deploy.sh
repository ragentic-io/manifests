#!/usr/bin/env bash
# Rolls manifests.ragentic.io (Deployment manifests, namespace manifests) onto
# one image, the way .github/workflows/deploy.yml does from the in-cluster
# runner "manifests-deploy" (deploy/README.md "Pipeline"):
#
#   1. mirror IMAGE (ghcr.io) into Harbor as ragentic-manifests:main-<sha12>,
#      so the nodes keep pulling from the LAN registry (never :latest);
#   2. pin the migrate init container and the registry container to that digest;
#   3. wait for the rollout; if it does not finish, undo it;
#   4. check that the public index is the commit's catalog/index.json and that
#      a published manifest resolves.
#
#   scripts/deploy.sh IMAGE SHA
#
# Run from the checkout of SHA (step 4 compares against its catalog/index.json).
# CI supplies GHCR_TOKEN; manual callers can use GHCR_DOCKERCONFIG instead.
# Harbor credentials and CA come from the runner's mounts; override with
# HARBOR_DOCKERCONFIG and HARBOR_CA to run it elsewhere.
# Disable tracing before expanding credentials, including their base64 form.
set +x
set -euo pipefail

image="${1:?usage: deploy.sh IMAGE SHA}"
sha="${2:?usage: deploy.sh IMAGE SHA}"
ns="${DEPLOY_NAMESPACE:-manifests}"
harbor="${HARBOR_REPO:-harbor.home/library/ragentic-manifests}"
public="${PUBLIC_URL:-https://manifests.ragentic.io}"
ghcr_cfg="${GHCR_DOCKERCONFIG:-/etc/deploy/ghcr/.dockerconfigjson}"
harbor_cfg="${HARBOR_DOCKERCONFIG:-/etc/deploy/harbor/.dockerconfigjson}"
harbor_ca="${HARBOR_CA:-/etc/deploy/harbor-ca/ca.crt}"
timeout="${ROLLOUT_TIMEOUT:-10m}"
[ -f catalog/index.json ] || { echo "::error::run from the checkout of $sha (no catalog/index.json)"; exit 1; }
umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

say() { printf '\n== %s\n' "$*"; }

# CI uses its short-lived package-read token; manual callers may still provide
# GHCR_DOCKERCONFIG. Never persist the workflow token in the cluster.
if [ -n "${GHCR_TOKEN:-}" ]; then
  : "${GITHUB_ACTOR:?GitHub actor required with GHCR_TOKEN}"
  ghcr_cfg="$work/ghcr.json"
  ghcr_auth="$(printf '%s:%s' "$GITHUB_ACTOR" "$GHCR_TOKEN" | base64 -w0)"
  printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$ghcr_auth" > "$ghcr_cfg"
  unset ghcr_auth GHCR_TOKEN
fi

# one docker config with both registries' logins, and a CA bundle that trusts
# the public registries and the home lab CA
jq -s '{auths: (.[0].auths + .[1].auths)}' "$ghcr_cfg" "$harbor_cfg" > "$work/config.json"
export DOCKER_CONFIG="$work"
for sys in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
  [ -f "$sys" ] && { cat "$sys" "$harbor_ca" > "$work/ca.crt"; break; }
done
export SSL_CERT_FILE="$work/ca.crt"

target="$harbor:main-${sha::12}"
say "mirror $image → $target"
crane copy "$image" "$target"
digest="$(crane digest "$target")"
[[ "$digest" == sha256:* ]] || { echo "::error::no digest for $target"; exit 1; }
# tag@digest, as the hand procedure pins it: the tag names the commit, the
# digest is what the kubelet pulls
pinned="$target@$digest"

say "roll $ns/manifests onto $pinned"
before="$(kubectl -n "$ns" get deploy manifests -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "was: $before"
if [ "$before" = "$pinned" ]; then
  echo "already running this digest"
else
  kubectl -n "$ns" set image deploy/manifests migrate="$pinned" registry="$pinned"
  kubectl -n "$ns" annotate deploy/manifests --overwrite \
    kubernetes.io/change-cause="deploy ${sha::12} ($pinned)"
  if ! kubectl -n "$ns" rollout status deploy/manifests --timeout="$timeout"; then
    say "the rollout did not finish: what the pods say"
    kubectl -n "$ns" get pods -l app=manifests -o wide || true
    kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
    for p in $(kubectl -n "$ns" get pods -l app=manifests -o name); do
      echo "--- $p (migrate)"; kubectl -n "$ns" logs "$p" -c migrate --tail=40 2>&1 || true
      echo "--- $p (registry)"; kubectl -n "$ns" logs "$p" -c registry --tail=40 2>&1 || true
    done
    say "undo: back to $before"
    kubectl -n "$ns" rollout undo deploy/manifests || true
    echo "::error::the rollout of ${sha::12} did not become ready within $timeout and was undone"
    exit 1
  fi
fi

# Readiness already waits for a signed index; this checks that the public name
# serves this commit's index (not an older pod's, nor a rolled-back catalog)
# and that the API resolves a published manifest.
say "smoke"
for _ in $(seq 1 30); do
  if curl -fsS -m 10 "$public/v1/index.json" -o "$work/index.json" && cmp -s "$work/index.json" catalog/index.json; then
    code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$public/api/v1/manifests/stripe-openapi?version=latest" || true)"
    if [ "$code" = 200 ]; then
      echo "index.json matches catalog/index.json; stripe-openapi@latest 200"
      echo "deployed ${sha::12}"
      exit 0
    fi
    echo "stripe-openapi@latest: $code"
  fi
  sleep 10
done
echo "::error::$public does not serve ${sha::12}'s catalog/index.json, or /api/v1/manifests/stripe-openapi?version=latest is not 200"
exit 1
