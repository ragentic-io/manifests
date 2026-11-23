# Catalog label taxonomy

Labels describe what an application in this catalog is, so people can filter the catalog
(Ragentic's `/catalog/registries`, `?label=category=finance&label=auth=oauth2`). The set is
small and fixed: [`taxonomy.json`](taxonomy.json) is the machine-readable schema, and
[`label.py`](label.py) rejects any key or value outside it.

Labels use **Kubernetes label syntax**: a key and a string value, the value at most 63
characters of `[a-z0-9]`, `-`, `_` and `.`, starting and ending alphanumeric. They live in
the bundle payload at `manifest.metadata.labels`, a flat object of strings:

```json
"metadata": {
  "name": "stripe-openapi",
  "labels": {
    "category": "finance",
    "vendor": "stripe",
    "protocol": "openapi",
    "auth": "bearer",
    "capability.read": "true",
    "capability.write": "true",
    "capability.payments": "true",
    "provides": "payments",
    "audience": "finance",
    "pricing": "paid",
    "maturity": "published"
  }
}
```

## Keys

| Key | Values | Rule |
| --- | --- | --- |
| `category` | an id from [`../categories.json`](../categories.json): `ai`, `analytics`, `business`, `cloud`, `communication`, `ecommerce`, `education`, `finance`, `health`, `iot`, `location`, `marketing`, `media`, `open-data`, `productivity`, `security`, `social-media`, `software-development`, `travel` | One primary category, normally one of the listing's `categories`. |
| `vendor` | lowercase slug (`stripe`, `google`, `apache`) | Not enumerated; must be a DNS-label-like slug. |
| `protocol` | `openapi`, `graphql`, `asyncapi`, `grpc`, `atproto` | **Derived** from the bundle's `protocol`, never from the model. |
| `auth` | `oauth2`, `api-key`, `bearer`, `basic`, `app-password`, `none` | Derived from `setup.credential` when present (`static_bearer`→`bearer`, `api_key_header`→`api-key`, `oauth2_authorization_code`→`oauth2`, `basic`, `none`, `atproto_session`→`app-password`); otherwise from the definition's security schemes. |
| `capability.<x>` | `"true"`; `<x>` one of `read`, `write`, `delete`, `post`, `files`, `search`, `webhooks`, `streaming`, `messaging`, `payments`, `admin` | Several allowed, one key each. |
| `provides` | `payments`, `source-control`, `tickets`, `chat`, `customer-support`, `realtime-messaging`, `social-media`, `design`, `design-files`, `whiteboard`, `identity`, `feature-flags`, `cloud-infra`, `research-data`, `website-cms` | The one job a coworker's need asks the app for. Ragentic offers the app on the Connect card for a need `{provides: payments}` (ragentic `docs/filling-gaps.md`). One value; omit when no single job fits. Set by hand for published apps. |
| `audience` | `developer`, `marketing`, `operations`, `finance`, `sales`, `support`, `data`, `security`, `general` | Who mainly uses it. |
| `region` | `us`, `eu`, `uk`, `ca`, `au`, `in`, `apac`, `latam`, `africa`, `mena` | Only for APIs bound to one jurisdiction or market; omitted for global services. |
| `compliance` | `gdpr`, `hipaa`, `pci-dss`, `psd2`, `fedramp`, `sox` | Only when the API exists for a regulated domain (open banking → `psd2`); never inferred from a vendor's certifications. |
| `pricing` | `free`, `freemium`, `paid` | Omitted when unknown. |
| `maturity` | `published`, `draft` | **Derived** from the listing's `catalog`, never from the model. |

A missing key means "unknown", not "no". Filters therefore match only applications that
carry the label.

## Changing the taxonomy

Add a value or key in `taxonomy.json` and this table in the same PR, bump `version`, and
rerun `label.py propose`: the cache key includes the taxonomy digest, so every application
is labeled again under the new taxonomy. Removing a value invalidates existing labels;
run `label.py check` to list them. Keep the set small: a filter with 40 values is a search box.

## Tooling

```sh
python3 -I catalog/labels/label.py propose   # cheap model, cached, writes proposals.json + last-run.json
python3 -I catalog/labels/label.py check     # validate proposals.json against the taxonomy
python3 -I catalog/labels/label.py apply     # drafts: manifest.metadata.labels; published: resign.json
python3 -I -m unittest discover -s catalog/labels -p 'test_*.py'
```

`propose` sends batches (default 25 apps, 4 at once, a list-price budget cap of $15) to
the Ragentic agent `engineering/catalog-labeler` (model `claude-max/sonnet`) through
`ragentic call ask_agent`, so no provider key is in this repository. It retries transient
failures, saves `cache.json` after every batch (an interrupted run resumes), and only asks
about payloads whose digest changed. `last-run.json` reports tokens and cost.
How labels reach signed index entries: [`../drafts/PUBLISHING.md`](../drafts/PUBLISHING.md#labels).

## Labels in the index

`mix catalog.sign` (and `tools/catalog.py sign`) copies a bundle's `manifest.metadata.labels`
into its index entry as `labels`, so clients filter and match on them from the signed index
alone, without selecting each bundle. Ragentic's entry schema (`RagenticManifests.Entry`) keeps
them; Ragentic before 2026-11-21 (#679) has no `labels` field.
