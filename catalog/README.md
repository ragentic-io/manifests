# Ragentic manifest catalog

The source of truth for the applications served at `https://manifests.ragentic.io`.
Anyone can propose a new service or an improvement with a pull request. CI
validates every change, and after a maintainer merges it, the Sign workflow signs it
with the registry's Ed25519 root key. Every file here, plain text and transport
alike, is covered by that one key.

See [CATALOG.md](CATALOG.md) for every application and its status.

## Layout

| Path | What it is | Who writes it |
| --- | --- | --- |
| `apps/<id>/manifest.json` | The application's bundle payload, pretty-printed: the connector template, the embedded API definition, its operation graph, provenance, rights and setup | Contributors |
| `apps/<id>/MANIFEST.md` | Front matter with the catalog listing (`title`, `catalog`, `categories`, optional `logo`), then a generated human-readable summary: endpoint, credential, source, license, review checklist and every operation | Contributors (front matter); `mix catalog.docs` (body) |
| `CATALOG.md` | Generated table of every application | `mix catalog.docs` |
| `index.json`, `bundles/` | Signed catalog of **published** applications, which people can connect | Sign workflow |
| `browse-index.json`, `browse-bundles/` | Signed catalog of **draft** applications, which can be browsed but not connected | Sign workflow |
| `sources.json` | Signed SHA-256 list of every plain-text file under `apps/` plus `CATALOG.md` | Sign workflow |
| `categories.json` | The categories applications are labelled with, so people can filter the catalog | Maintainers |
| `deploy/` | The CronJob that deploys the newest signed catalog on `main` to manifests.ragentic.io, after checking it with the server's own loader | Maintainers |
| `registry.json` | Registry identity, pinned public root and signature lifetimes | Maintainers |
| `mix catalog.*` | Scaffolding, validation, docs and signing: Mix tasks in the repository root (`lib/mix/tasks/catalog.*.ex`, `lib/manifests/catalog_tools/`) | Maintainers |
| `tools/catalog.py` | The original Python tool, superseded by the Mix tasks, which write byte-identical output. Kept for reference for now | Maintainers |

Paths in this README are relative to `catalog/`. The Mix tasks run from the
repository root and use `catalog/` by default; pass `--root DIR` to work on another
copy.

Signed objects are canonical JSON wrapped in `{"payload", "signature"}` envelopes. The
signature is Ed25519 over `ragentic.manifests/v1\n` followed by the payload bytes. A
bundle's file name is the SHA-256 of its payload bytes.

## The operation graph

Each OpenAPI application's `graph` is generated from its embedded definition by
`mix catalog.graph <id>`, and `validate` checks that it is current.

| Node | Fields |
| --- | --- |
| `application` | `id` |
| `operation` | `name` (operationId), `method`, `path`, `summary`, `description` (first sentence), `tags`, `security`, `deprecated`, `pointer` into the definition, `parameters` (`name`, `in`, `required`, `type`, `description`, `enum`, `default`), `request` (`content_types`, `required`, `type`), `responses` (`status`, `type`), and `safe` |
| `schema` | `name`, `type`, `description` |

| Edge | Meaning |
| --- | --- |
| `EXPOSES` | application → operation |
| `ACCEPTS` | operation → schema of its request body |
| `RETURNS` | operation → schema of a 2xx response |
| `REFERENCES` | schema → schema it refers to |

Types are compact: `Pet`, `Pet[]`, `string:date-time`, `A|B`. `safe` is true for
`GET`, `HEAD` and `OPTIONS`, the operations that only read. These fields are what a
tool-calling model such as Ragentic's Needle needs to pick an operation and fill its
arguments. `safe` marks the operations a future Needle-powered preview call can run
against a connection without side effects.

## Register a new service

You need Elixir (see `mix.exs` in the repository root) and a public OpenAPI 3 or
Swagger 2 definition published by the provider. Run every command below from the
repository root, not from `catalog/`.

1. **Fork and clone** this repository, then fetch the dependencies:

   ```sh
   mix deps.get
   ```

   The catalog tasks don't start the application, so they need no database.

2. **Pick an id.** Use lowercase letters, digits, `.`, `_` and `-`, starting with a
   letter or digit, for example `acme-openapi`. Check that `apps/<id>` doesn't exist
   and the service isn't already listed in [CATALOG.md](CATALOG.md) under another id.

3. **Scaffold the draft** from the provider's definition:

   ```sh
   mix catalog.new acme-openapi \
     --openapi https://developer.acme.com/openapi.json \
     --title "Acme" \
     --category finance --category ecommerce \
     --credential api_key_header --header Authorization --prefix Bearer
   ```

   This fetches the definition (JSON or YAML; `file://` URLs work too) and embeds it. It records its URL and SHA-256 under
   `provenance`, generates the operation graph and writes
   `catalog/apps/acme-openapi/manifest.json` and `MANIFEST.md`. Leave out `--credential` if
   you don't know the authentication yet. `--endpoint` overrides the base URL, which
   otherwise comes from the definition's first `https` server.

4. **Review and complete `manifest.json`:**
   - `manifest.spec.title` and `description`: the provider's own name and a one-line summary.
   - `manifest.spec.base.endpoint`: the production `https` base URL.
   - `provenance.license`: the definition's license. Only submit definitions whose
     license allows redistribution.
   - `setup.credential`: `none`, `static_bearer`, or `api_key_header` with `header`
     and `prefix`. Never put a real key, token or password anywhere in the file.
   - If you edit the embedded definition, run `mix catalog.graph <id>` to
     regenerate the graph.

5. **Check the listing** in the front matter of `MANIFEST.md`. Values are JSON:

   ```yaml
   ---
   title: "Acme"
   catalog: "drafts"
   categories: ["finance", "ecommerce"]
   logo: "https://acme.com/favicon.svg"
   ---
   ```

   New services always start in `drafts`. `categories` lists one to four ids from
   [categories.json](categories.json), most relevant first. They appear in `MANIFEST.md` and
   `CATALOG.md` and are covered by `sources.json`, but are not yet part of index
   entries, whose schema the registry server and Ragentic fix. `logo` is optional and must be
   `https`.

6. **Regenerate the docs and validate:**

   ```sh
   mix catalog.docs
   mix catalog.validate
   ```

   `validate` must end with `ok`. Your application is reported as
   `pending … not signed yet`, which is expected.

7. **Open a pull request** that changes only `apps/` and `CATALOG.md`, and fill in
   the checklist. The Validate workflow runs the same checks and prints the signing
   plan. Pull requests from forks may not touch signed objects, `registry.json`,
   `tools/` or `.github/`.

8. **After merge**, the Sign workflow signs the new bundle and adds it to
   `browse-index.json` with the next sequence number. It also commits the signed
   files, and the application shows as `signed` in [CATALOG.md](CATALOG.md).

### Updating or removing a service

Edit `apps/<id>/manifest.json` or the front matter, run `docs` and `validate`, and
open a pull request. The Sign workflow re-signs only what changed. Deleting
`apps/<id>` removes the application from its index and deletes its bundle when the
change is signed.

### Promoting a draft to published

Published applications can be connected in Ragentic, so they need a complete setup.
Change `catalog: "drafts"` to `catalog: "published"` only when `manifest.json` has:

- a `readiness` other than `discovered` or `preview_only`
- `setup.credential` and a `setup.probe` connection test
- `rights.source` (license and copyright) and `rights.brand` (attribution)
- an `a2ui` setup form

Use a published application with the same credential type as a template, for
example `apps/govuk-pay`. `validate` enforces these requirements. Say in the pull
request how you tested the connection.

## Validation rules

`mix catalog.validate` checks the following:

- **Signatures:** both indexes, every bundle they name and `sources.json` verify
  against the root in `registry.json`. Digests match file names, and no bundle is
  left unreferenced.
- **Each application:**
  - Its id, protocol, version, `manifest` template and provenance are valid.
  - It embeds its definition (an OpenAPI document, or GraphQL SDL).
  - Its graph edges join known nodes.
  - OpenAPI graphs match the definition.
- **Listing:** the title, catalog, categories and logo are valid, and published applications meet
  the promotion requirements.
- **Safety:** no credential-like strings in `setup`, `a2ui` or the base headers, and
  every payload is under 16 MiB.
- **Generated docs:** `MANIFEST.md` bodies and `CATALOG.md` are up to date.

`mix catalog.validate --require-signed` also fails if anything is waiting for signature. The Sign
workflow runs it after signing.

## Signing (maintainers)

This catalog lives in `ragentic-io/manifests`, beside the registry server that
publishes it, so the repository and the server never sign competing sequence
numbers. The Sign workflow (`.github/workflows/sign.yml`) runs on every push to
`main` that touches `catalog/apps/`, `catalog/registry.json` or the signing tools
(`lib/mix/tasks/catalog*`, `lib/manifests/catalog_tools/`), daily at 06:17 UTC,
and on demand (`gh workflow run sign.yml`). It runs `mix catalog.validate`,
`mix catalog.sign` with the key in `MANIFESTS_SIGNING_KEY`, then
`mix catalog.validate --require-signed`. For each application whose sources
differ from its signed bundle, or whose signature expires within `refresh_days`,
`mix catalog.sign`:

1. Sets `not_before` and `expires` (`validity_days` ahead) and signs the canonical
   payload into `bundles/` or `browse-bundles/`.
2. Writes the new times back into `manifest.json`, so the sources keep matching.
3. Rebuilds each index whose entries changed or that is close to expiry, keeping
   existing order. It increments the sequence and deletes bundles the index no
   longer names.
4. Regenerates the docs and signs `sources.json` over every plain-text file.

The workflow commits the result to `main` as `github-actions[bot]` ("Sign
catalog: index sequence N, browse sequence M") and dispatches CI for that commit;
CI's success on `main` starts the deploy workflow, which bakes the new index into
the image and rolls manifests.ragentic.io (deploy/README.md "Pipeline").

Preview the plan without a key with `mix catalog.sign --dry-run`. Pull requests
only change sources: CI's `mix catalog.validate` accepts unsigned drafts and
rejects sources that disagree with a signed bundle in any other way. Never sign
on a workstation; a locally signed sequence races the workflow's.

`mix catalog.import` rebuilds `apps/` from the signed objects, keeping each
application's categories.

One-time setup:

1. Create a GitHub environment named `registry-signing`, with deployment branches
   restricted to `main`.
2. Add the root private key to that environment as the secret
   `MANIFESTS_SIGNING_KEY`, as a 32-byte Ed25519 seed in hex or base64url. The tool
   refuses a key that doesn't match the pinned root (`c05bcbfb…` in
   `registry.json`).
3. Protect `main`: require pull requests and the CI check. Allow
   `github-actions[bot]` to push the signing commit, for example as a ruleset
   bypass actor.

## Using this catalog

Configure Ragentic's **Git repository** registry source with this repository URL,
the full 40-character commit SHA of a signed commit, and an empty catalog prefix. A
branch or tag name is intentionally unsupported. Pin the registry identity
`manifests.ragentic.io`, a minimum sequence no lower than the one you last trusted,
and the independently obtained Ed25519 public root:

```text
base64url: wFvL-3yCuZX52nrDbSxvTgeb5s4KFp6aS2W8JikogGs
SHA-256 fingerprint: 97743a2782a18cd7365bd220992c84408766302f6236537c4df8127a468984b9
```

Do not establish trust from this repository alone; compare the public root through a
separate trusted channel. Signed objects expire, so use a recent signed commit.
Private signing keys are never stored here.
