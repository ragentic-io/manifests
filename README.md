# Ragentic manifests

This repository contains the application connector catalog served at
[manifests.ragentic.io](https://manifests.ragentic.io/), the tools that validate and
sign it, and the Phoenix registry server that publishes it. Each application
entry combines an API definition, a Ragentic `ConnectorTemplate`, an operation
graph, provenance, and setup information. Use these reusable definitions to create
connections in your own Ragentic workspace.

Start with the [application directory](catalog/CATALOG.md) or the
[searchable public catalog](https://manifests.ragentic.io/). The catalog includes
OpenAPI / Swagger, GraphQL and AsyncAPI definitions. The generated application
directory lists the current applications, publication states and counts.

**Published** applications have reviewed setup and can be connected in Ragentic.
**Drafts** are available for discovery and definition previews; they require
review before connections can be enabled. Both catalogs are signed. A valid
signature authenticates an entry's origin and integrity; it does not promote a
draft to published or prove that a provider connection was tested live.

## Repository layout

All paths below are relative to the repository root.

| Path | Contents / owner |
| --- | --- |
| [`catalog/apps/`](catalog/apps/) | Editable source for every application, including drafts: one directory per stable application id. Contributors edit `manifest.json` and the front matter of `MANIFEST.md`. |
| [`catalog/CATALOG.md`](catalog/CATALOG.md) | Generated listing, categories, publication state and signing status for all applications. |
| [`catalog/categories.json`](catalog/categories.json) | Allowed category ids and descriptions. |
| [`catalog/registry.json`](catalog/registry.json) | Registry identity, public verification root and signature refresh settings. |
| [`catalog/index.json`](catalog/index.json), [`catalog/bundles/`](catalog/bundles/) | Signed published index and bundles, written by the Sign workflow. |
| [`catalog/browse-index.json`](catalog/browse-index.json), [`catalog/browse-bundles/`](catalog/browse-bundles/) | Signed draft index and bundles, also written by Sign. |
| [`catalog/sources.json`](catalog/sources.json) | Signed SHA-256 inventory of the files under `catalog/apps/`, plus `catalog/CATALOG.md` and `catalog/categories.json`. |
| [`lib/mix/tasks/`](lib/mix/tasks/), [`lib/manifests/catalog_tools/`](lib/manifests/catalog_tools/) | Current catalog authoring, graph generation, documentation, validation and signing tools. |
| [`lib/manifests/`](lib/manifests/), [`lib/manifests_web/`](lib/manifests_web/), [`priv/`](priv/) | Registry persistence/import, Phoenix pages and HTTP endpoints, migrations and static assets. |
| [`test/`](test/), [`config/`](config/), [`assets/`](assets/) | Server tests, environment configuration and web assets. |
| [`.github/workflows/`](.github/workflows/), [`Dockerfile`](Dockerfile), [`scripts/`](scripts/), [`deploy/`](deploy/) | CI, signing, image build and deployment implementation. |
| [`catalog/tools/`](catalog/tools/), [`catalog/drafts/`](catalog/drafts/), [`catalog/deploy/`](catalog/deploy/) | Earlier Python tooling, social-app preparation artifacts and catalog-sync deployment files. Use the Mix tasks and root workflows for the current contribution and publication process. |

An application's `manifest.json` is the editable bundle payload. It embeds the
API definition under `manifest.spec.base.specification`, the operation graph,
provenance, and any `setup`, `rights` and `a2ui` setup UI. `MANIFEST.md` contains
editable listing front matter followed by a generated summary and operations.
OpenAPI graphs are generated from the embedded definition; GraphQL and AsyncAPI
graphs are maintained by hand. For examples, inspect
[GOV.UK Pay](catalog/apps/govuk-pay/manifest.json) and
[GitHub GraphQL](catalog/apps/github-graphql/manifest.json).

## Use an entry in Ragentic

1. In Ragentic's connector catalog, choose **Manifest registries**
   (`/catalog/registries` on your instance).
2. Select `manifests.ragentic.io`. Ragentic enrolls the built-in source using
   the operator's configured public-key pin and verifies the catalog.
3. Search by application name or API type. **View definition** previews an
   entry; **Set up connection** is available for published applications.
4. Follow the application's setup guide, choose a connection name and workspace,
   supply the requested credential or authorize with the provider, test access,
   and save the connection. Credentials belong in your Ragentic instance, never
   in a catalog contribution.

To add the source explicitly, expand **Add a trusted registry** and use:

| Setting | Value |
| --- | --- |
| Transport | Manifest site |
| HTTPS base URL | `https://manifests.ragentic.io/v1` |
| Signed registry identity | `manifests.ragentic.io` |
| Ed25519 public key (hex) | `c05bcbfb7c82b995f9da7ac36d2c6f4e079be6ce0a169e9a4b65bc262928806b` |
| Minimum catalog sequence | Your independently trusted published-index sequence; never lower a previously trusted value. |

This is a **public verification key**, not a private signing key. Confirm it
through a separate trusted channel before first enrollment. Ragentic also checks
signature validity periods and tracks catalog sequences to prevent rollback.

For a Git-backed source, select **Git repository**, set the repository to
`https://github.com/ragentic-io/manifests`, use the full 40-character SHA of a
recent commit containing a fully signed catalog, and set **Catalog directory / prefix** to **`catalog`**.
Keep the same identity and public-key pin. Branch and tag names are not accepted;
update the pinned commit before its signed objects expire.

### Read the public API

The server offers a [search API](https://manifests.ragentic.io/api/v1/manifests),
[labels](https://manifests.ragentic.io/api/v1/labels), application details,
version history and signed bundle downloads. For example, this downloads the
signed Stripe bundle to a local file:

```sh
curl --fail --silent --show-error \
  'https://manifests.ragentic.io/api/v1/manifests/stripe-openapi/bundle?version=latest' \
  --output stripe-bundle.json
```

Details and bundle requests require `?version=latest`, an exact version, or
`?version=sha256:<digest>`; omitting it returns `version_required`.
Use the [version history](https://manifests.ragentic.io/api/v1/manifests/stripe-openapi/versions)
to find an immutable digest. A download alone does not verify trust: Ragentic's
registry client consumes the signed [published index](https://manifests.ragentic.io/v1/index.json)
and [draft index](https://manifests.ragentic.io/v1/browse-index.json), then verifies
selected bundles against its pinned root.

## Add or change an application

Fork or clone this repository and create a branch from current `main`. Install
Git, Elixir and Erlang/OTP; the tested CI versions are **Elixir 1.20.4 / OTP
29.1.2** (see [CI](.github/workflows/ci.yml)). Native dependencies also need a C
compiler and Make. Run these commands from the **repository root**, not
`catalog/`:

```sh
mix deps.get
mix compile --warnings-as-errors
```

Catalog tasks do not start the server and need no database. They default to
`catalog/`; `--root DIR` selects another catalog copy.

1. Search the application directory for an existing entry, including alternative
   names. Choose a new stable id matching `[a-z0-9][a-z0-9._-]{0,127}`.
2. Obtain the provider's OpenAPI 3 or Swagger 2 definition and check that its
   license permits redistribution. The scaffold accepts JSON or YAML over HTTPS
   or a local `file://` URL. This runnable example creates a **draft** from
   Swagger's public Petstore demonstration API:

   ```sh
   mix catalog.new petstore-example \
     --openapi https://petstore3.swagger.io/api/v3/openapi.json \
     --title "Petstore example" \
     --category software-development \
     --endpoint https://petstore3.swagger.io/api/v3
   ```

   Use your service's id and definition when contributing. Omit credential
   configuration until it has been reviewed; Petstore illustrates scaffolding,
   not a ready-to-connect integration. Scaffolding records the source URL,
   SHA-256 and fetch time, embeds the definition and generates the graph.
3. Review `catalog/apps/<id>/manifest.json`: title, description, production HTTPS
   endpoint, embedded definition, version, provenance and redistribution rights.
   Complete the authentication/setup contract using a published application with
   the same authentication style as a reference. The scaffold supports
   `--credential none`, `static_bearer`, or `api_key_header` with `--header` and
   optional `--prefix`; see [its full options](lib/mix/tasks/catalog.new.ex).
   Never include real tokens, passwords or private keys.
4. Edit only the front matter of `MANIFEST.md`. It uses JSON values: `title` is a
   string, `catalog` starts as `"drafts"`, and `categories` lists one to four
   distinct ids from `catalog/categories.json`. An optional `logo` must use HTTPS.
   The body is generated and will be overwritten.
5. After changing an OpenAPI definition, regenerate its operation graph. For
   the example above:

   ```sh
   mix catalog.graph petstore-example
   ```

   For GraphQL or AsyncAPI, start from an existing entry of that protocol and
   edit the embedded definition and graph together; the scaffold and graph
   generator support OpenAPI only.
6. Regenerate the docs and validate as described below, review the diff, and
   open a pull request to `main`. Application contributions normally change
   only `catalog/apps/<id>/` and generated `catalog/CATALOG.md`.

To **update** an entry, edit those same source files and regenerate the graph
when needed. Update its version and provenance when the definition changes. To
**remove** one, delete its application directory and regenerate the docs; signing
removes it from the current index and prunes its unreferenced bundle files.

### Promote a draft to published

A published entry needs a reviewed, working connection flow. Set its front
matter `catalog` to `"published"` and `manifest.spec.status` to `"published"`.
Provide a readiness other than `discovered` or `preview_only`, a
`setup.credential`, a `setup.probe` connection test, source license information in
`rights.source`, brand attribution in `rights.brand`, and a nonempty
`a2ui.messages` setup form. Reuse an appropriate published entry's structure and
record how you tested authentication, permissions and the connection probe in
the PR. Validation checks structure; reviewers still need evidence that setup
works with the provider.

## Validate your change

After editing sources, run:

```sh
mix catalog.docs
mix catalog.validate
mix catalog.sign --dry-run
```

Validation must finish with **`ok`**. It checks application/listing structure,
embedded definitions, graph consistency, generated docs, payload size,
credential-like strings in setup/UI/base headers, existing signatures, bundle
digests and source inventory differences. New or changed entries can be reported
as **pending** until Sign processes them; ordinary validation allows this.
The dry run shows the signing plan without a key or writes.

For an unchanged signed catalog, or after the signing workflow, the stricter
check must also pass:

```sh
mix catalog.validate --require-signed
```

It fails while sources, listings or signed objects need signing/refresh. Some
legacy tool messages still mention Python commands; use the Mix tasks above.

For server/tool code changes, PostgreSQL must be available with the local settings
in [`config/test.exs`](config/test.exs). Run the repository's precommit alias with
a test database suffix unique to your checkout:

```sh
MIX_TEST_PARTITION=_manifests_readme_write mix precommit
```

This compiles with warnings as errors, removes unused lockfile entries, formats
code and runs tests. Inspect the diff afterward for unrelated generated changes.
[CI](.github/workflows/ci.yml) checks formatting, compilation, catalog validation
and the test suite on every PR.

## Signing and publication

Contributors submit editable sources, not locally signed catalog objects. Keep
private signing keys out of workstations and pull requests. The
[Sign workflow](.github/workflows/sign.yml) owns the sequence numbers and signs
with the `MANIFESTS_SIGNING_KEY` secret in the `registry-signing` GitHub environment.
It refuses a key that does not match the root pinned in `catalog/registry.json`.

After a maintainer merges application sources into `main`:

1. Sign validates the catalog, signs changed/expiring bundles and indexes,
   updates timestamps and index sequences, regenerates docs, and signs the
   plain-text source inventory. It commits the results back to `main`.
2. A new draft enters `browse-index.json`; a published entry enters `index.json`.
   Being merged or signed does not by itself promote a draft.
3. Sign dispatches CI for its signing commit. Successful CI on `main` starts
   the [deployment workflow](.github/workflows/deploy.yml), which builds the
   registry image with the catalog. Automatic rollout runs when the repository
   variable `AUTO_DEPLOY` is `true`.
4. The server verifies and imports that catalog, then serves the updated website,
   API and signed transport. Check the workflow results and the application's
   public page/version history to confirm publication. An initial deployment
   before Sign completes can still serve the previous signed catalog.

Sign also runs daily at **06:17 UTC** and supports manual dispatch from GitHub
Actions. Signatures currently last 90 days and refresh within 21 days of expiry;
these settings live in `catalog/registry.json`. Maintainers provision the matching
private key as an environment secret, restrict that environment to `main`, and
allow the signing bot to push its generated commit through branch protection.

Bundles are canonical JSON in signed envelopes. Ed25519 signs the domain prefix
`ragentic.manifests/v1\n` plus the payload bytes; bundle filenames contain the
SHA-256 of those bytes. This lets clients verify content independently of the
website or Git transport.

## Contribute

Open a PR against `main` with the application's purpose, definition source and
license, files changed, validation results, and any live connection testing.
Explain authentication, required permissions and review still needed; leave an
incomplete integration in drafts. For documentation-only work, check every
example and link. Propose changes to signing policy, categories or workflows
separately from application additions.

Wait for CI and maintainer review. Do not edit generated signed bundles,
indexes or `sources.json` to make a contribution appear published: the signing
and deployment workflows produce those artifacts after review. Report catalog
problems through [repository issues](https://github.com/ragentic-io/manifests/issues)
with the application id and version/digest, excluding credentials.
