#!/usr/bin/env python3
"""Propose taxonomy labels for every catalog application with a low-cost model.

    python3 -I catalog/labels/label.py propose [--concurrency 4] [--batch 25] [--budget-usd 15]
    python3 -I catalog/labels/label.py apply
    python3 -I catalog/labels/label.py check      # validate proposals.json, no model calls

What it labels:
  * published applications: the signed bundle named by catalog/index.json, decoded read-only
    (catalog/bundles/ is never written);
  * draft applications: catalog/apps/<id>/manifest.json whose MANIFEST.md says catalog "drafts";
  * the unsigned social build outputs: catalog/drafts/<app>/payload.json (ids "drafts/<app>").

The model is reached through Ragentic, so no provider key lives here: `ragentic call ask_agent`
to the agent engineering/catalog-labeler (model claude-max/sonnet: Claude Code on DJ's machine
through the Ragentic relay), polling `ragentic call agent_turn`. jev (TypeSafe System One) was not
used: it returns typed decisions only (choice/score, no text), so it cannot return a label object
with a reason in one call.

Every answer is validated against taxonomy.json: a key or value outside it is dropped and listed
under "rejected", never guessed or coerced. protocol and maturity come from the bundle and listing,
and auth from setup.credential when the bundle has one; those override the model.

Results are cached in cache.json by the payload digest (sha256 of the canonical payload without
manifest.metadata.labels, so applying labels does not invalidate the cache) plus the taxonomy and
prompt version. Re-running only asks about applications whose payload changed, and an interrupted
run resumes from the cache (it is written after every batch).
"""
import argparse
import base64
import concurrent.futures
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
CATALOG = HERE.parent
PROMPT_VERSION = 1
AGENT = "engineering/catalog-labeler"
MODEL = "claude-max/sonnet"

CREDENTIAL_AUTH = {
    "static_bearer": "bearer",
    "api_key_header": "api-key",
    "oauth2_authorization_code": "oauth2",
    "basic": "basic",
    "none": "none",
    "atproto_session": "app-password",
}


# --- taxonomy and validation -------------------------------------------------------


def load_taxonomy(path=HERE / "taxonomy.json"):
    path = pathlib.Path(path)
    tax = json.loads(path.read_text())
    for key, spec in tax["keys"].items():
        if "values_from" in spec:
            ids = [c["id"] for c in json.loads((path.parent / spec["values_from"]).read_text())]
            spec["values"] = ids
    tax["digest"] = hashlib.sha256(json.dumps(tax, sort_keys=True).encode()).hexdigest()[:16]
    return tax


def _flatten(raw):
    """Model output -> list of (key, value). Accepts capability: [..] and capability.x: "true"."""
    out = []
    if not isinstance(raw, dict):
        return out
    for key, value in raw.items():
        if isinstance(value, list):
            out.extend((f"{key}.{v}", "true") if isinstance(v, str) else (key, v) for v in value)
        else:
            out.append((key, value))
    return out


def validate(raw, tax):
    """Return (labels, rejected): labels is a flat {key: value} within the taxonomy."""
    labels, rejected = {}, []
    vpat = re.compile(tax["value_pattern"])
    for key, value in _flatten(raw):
        if not isinstance(key, str) or not isinstance(value, str):
            rejected.append(f"{key}={value!r}")
            continue
        base, _, sub = key.partition(".")
        spec = tax["keys"].get(base)
        ok = False
        if spec is None or spec.get("derived"):
            ok = False
        elif spec.get("multi"):
            ok = sub in spec["values"] and value == "true"
        elif sub:
            ok = False
        elif "values" in spec:
            ok = value in spec["values"]
        elif "pattern" in spec:
            ok = bool(re.match(spec["pattern"], value))
        ok = ok and bool(vpat.match(value))
        if ok:
            labels[key] = value
        else:
            rejected.append(f"{key}={value}")
    return labels, rejected


def check_labels(labels, tax):
    """Errors for a full label set (including derived keys), for `check` and the tests."""
    errors = []
    vpat = re.compile(tax["value_pattern"])
    for key, value in labels.items():
        base, _, sub = key.partition(".")
        spec = tax["keys"].get(base)
        if spec is None:
            errors.append(f"unknown key {key}")
        elif spec.get("multi"):
            if sub not in spec["values"] or value != "true":
                errors.append(f"bad {key}={value}")
        elif sub:
            errors.append(f"unknown key {key}")
        elif "values" in spec and value not in spec["values"]:
            errors.append(f"bad {key}={value}")
        elif "pattern" in spec and not re.match(spec["pattern"], value):
            errors.append(f"bad {key}={value}")
        elif not vpat.match(value):
            errors.append(f"bad {key}={value}")
    return errors


# --- catalog items -----------------------------------------------------------------


def b64(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def envelope_payload(path):
    """Decode a signed object read-only: {payload, signature} or a bundle {envelope, chain}."""
    obj = json.loads(pathlib.Path(path).read_text())
    env = obj.get("envelope", obj)
    return json.loads(b64(env["payload"]))


def front_matter(md_path):
    """MANIFEST.md front matter: JSON values, one key per line."""
    fm = {}
    lines = pathlib.Path(md_path).read_text().splitlines()
    if not lines or lines[0] != "---":
        return fm
    for line in lines[1:]:
        if line == "---":
            break
        key, _, value = line.partition(":")
        try:
            fm[key.strip()] = json.loads(value.strip())
        except json.JSONDecodeError:
            fm[key.strip()] = value.strip()
    return fm


def payload_digest(payload):
    """sha256 of the canonical payload without manifest.metadata.labels."""
    p = json.loads(json.dumps(payload))
    meta = (p.get("manifest") or {}).get("metadata")
    if isinstance(meta, dict):
        meta.pop("labels", None)
    data = json.dumps(p, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(data).hexdigest()


def collect(catalog=CATALOG):
    """Every labelable item: dicts with id, kind, path, digest, payload, listing."""
    catalog = pathlib.Path(catalog)
    signed = {}
    index = catalog / "index.json"
    if index.exists():
        for e in envelope_payload(index)["entries"]:
            signed[e["id"]] = e
    items = []
    for app_dir in sorted((catalog / "apps").iterdir()):
        mf = app_dir / "manifest.json"
        if not mf.exists():
            continue
        listing = front_matter(app_dir / "MANIFEST.md") if (app_dir / "MANIFEST.md").exists() else {}
        app_id = app_dir.name
        if listing.get("catalog") == "published":
            entry = signed.get(app_id)
            bundle = catalog / "bundles" / f"{entry['digest']}.json" if entry else None
            if bundle and bundle.exists():
                payload = envelope_payload(bundle)
                items.append(dict(id=app_id, kind="published", path=str(bundle.relative_to(catalog)),
                                  source=str(mf.relative_to(catalog)), signed_digest=entry["digest"],
                                  digest=payload_digest(payload), payload=payload, listing=listing))
                continue
            payload = json.loads(mf.read_text())
            items.append(dict(id=app_id, kind="published", path=str(mf.relative_to(catalog)),
                              source=str(mf.relative_to(catalog)), signed_digest=None,
                              digest=payload_digest(payload), payload=payload, listing=listing))
        else:
            payload = json.loads(mf.read_text())
            items.append(dict(id=app_id, kind="draft", path=str(mf.relative_to(catalog)),
                              digest=payload_digest(payload), payload=payload, listing=listing))
    drafts = catalog / "drafts"
    if drafts.exists():
        for d in sorted(drafts.iterdir()):
            p = d / "payload.json"
            if p.exists():
                payload = json.loads(p.read_text())
                items.append(dict(id=f"drafts/{d.name}", kind="social-draft", path=str(p.relative_to(catalog)),
                                  digest=payload_digest(payload), payload=payload,
                                  listing={"catalog": "drafts"}))
    return items


def _document(payload):
    spec = ((payload.get("manifest") or {}).get("spec") or {}).get("base") or {}
    doc = spec.get("specification")
    if isinstance(doc, dict) and isinstance(doc.get("document"), dict):
        return doc["document"]
    return doc if isinstance(doc, dict) else {}


def facts(item):
    """The small, label-relevant summary of an item that goes to the model."""
    payload, listing = item["payload"], item["listing"]
    doc = _document(payload)
    info = doc.get("info") if isinstance(doc.get("info"), dict) else {}
    desc = re.sub(r"<[^>]+>|\s+", " ", str(info.get("description") or "")).strip()
    schemes = doc.get("securityDefinitions") or (doc.get("components") or {}).get("securitySchemes") or {}
    sec = sorted({"/".join(str(s.get(k)) for k in ("type", "scheme", "in") if s.get(k))
                  for s in schemes.values() if isinstance(s, dict)})
    ops = [n for n in (payload.get("graph") or {}).get("nodes", []) if n.get("kind") == "operation"]
    servers = doc.get("servers") or []
    endpoint = (servers[0].get("url") if servers and isinstance(servers[0], dict) else None) or doc.get("host")
    cred = (payload.get("setup") or {}).get("credential")
    return {
        "id": item["id"],
        "title": listing.get("title") or (payload.get("manifest") or {}).get("spec", {}).get("title") or info.get("title"),
        "description": desc[:400],
        "protocol": payload.get("protocol"),
        "endpoint": endpoint,
        "categories": listing.get("categories"),
        "credential": cred.get("type") if isinstance(cred, dict) else cred,
        "security_schemes": sec,
        "provider": info.get("x-providerName"),
        "operation_count": len(ops),
        "operations": [f"{(o.get('method') or '').upper()} {o.get('path') or o.get('name')}".strip() for o in ops[:15]],
    }


def derived(item):
    """Labels that come from the bundle and listing, never from the model."""
    out = {}
    if item["payload"].get("protocol"):
        out["protocol"] = item["payload"]["protocol"]
    out["maturity"] = "published" if item["kind"] == "published" else "draft"
    cred = (item["payload"].get("setup") or {}).get("credential")
    ctype = cred.get("type") if isinstance(cred, dict) else None
    if ctype in CREDENTIAL_AUTH:
        out["auth"] = CREDENTIAL_AUTH[ctype]
    return out


# --- the model -----------------------------------------------------------------------


def prompt(tax, batch):
    keys = []
    for key, spec in tax["keys"].items():
        if spec.get("derived"):
            continue
        allowed = ", ".join(spec["values"]) if "values" in spec else f"slug matching {spec['pattern']}"
        many = " (a list: several allowed)" if spec.get("multi") else ""
        keys.append(f"- {key}{many}: {spec['description']} Allowed: {allowed}")
    return (
        "Label each API below with the taxonomy. Answer ONLY one JSON object, no prose, no code fence:\n"
        '{"<id>": {"labels": {"category": "...", "vendor": "...", "auth": "...", "capability": ["read", ...], '
        '"audience": "...", "pricing": "..."}, "reason": "<one line, under 20 words>"}, ...}\n'
        "Include every id. Use only these keys and values; leave a key out when the facts do not support it "
        "(region, compliance and pricing are often unknown). category should normally be one of the app's "
        "listed categories.\n\nTaxonomy:\n" + "\n".join(keys) +
        "\n\nApps:\n" + json.dumps([facts(i) for i in batch], ensure_ascii=False)
    )


class TransientError(Exception):
    pass


class AgentBackend:
    """Calls the labeler agent through the ragentic CLI (MCP tools ask_agent / agent_turn)."""

    def __init__(self, agent=AGENT, profile=None, timeout=900, poll=3.0):
        self.agent, self.profile, self.timeout, self.poll = agent, profile, timeout, poll

    def _call(self, tool, args):
        cmd = ["ragentic"] + (["-p", self.profile] if self.profile else []) + ["call", tool, "-d", "-", "--json"]
        r = subprocess.run(cmd, input=json.dumps(args), capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            raise TransientError(f"{tool}: {r.stderr.strip()[:300]}")
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError as e:
            raise TransientError(f"{tool}: not JSON: {r.stdout[:200]}") from e

    def __call__(self, text, conversation):
        started = self._call("ask_agent", {"agent": self.agent, "message": text, "conversation": conversation})
        turn = started.get("turn")
        if not turn:
            raise TransientError(f"ask_agent gave no turn: {started}")
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            time.sleep(self.poll)
            t = self._call("agent_turn", {"turn": turn})
            if t.get("state") == "done":
                usage = t.get("usage") or {}
                cost = t.get("cost") or {}
                return t.get("answer") or "", {
                    "input_tokens": usage.get("input_tokens", 0) + usage.get("cache_read_tokens", 0)
                    + usage.get("cache_creation_tokens", 0),
                    "output_tokens": usage.get("output_tokens", 0),
                    "list_cost": cost.get("list_cost") or 0.0,
                    "cost": cost.get("cost") or 0.0,
                }
            if t.get("state") == "error":
                raise TransientError(f"turn {turn}: {str(t.get('error'))[:300]}")
        raise TransientError(f"turn {turn} timed out")


def parse_answer(text):
    text = text.strip()
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text)
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < start:
        raise TransientError("answer has no JSON object")
    try:
        obj = json.loads(text[start:end + 1])
    except json.JSONDecodeError as e:
        raise TransientError(f"answer is not JSON: {e}") from e
    if not isinstance(obj, dict):
        raise TransientError("answer is not an object")
    return obj


# --- cache, run, outputs ---------------------------------------------------------------


def cache_key(item, tax):
    return f"{item['digest']}:{tax['digest']}:p{PROMPT_VERSION}"


def load_json(path, default):
    path = pathlib.Path(path)
    return json.loads(path.read_text()) if path.exists() else default


def dump_json(path, data):
    path = pathlib.Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def propose(items, tax, backend, cache_path, batch_size=25, concurrency=4, budget_usd=15.0,
            retries=3, backoff=2.0, log=print):
    """Label every uncached item; returns the run report. The cache is saved after each batch."""
    cache = load_json(cache_path, {})
    todo = [i for i in items if cache_key(i, tax) not in cache]
    report = {"items": len(items), "cached": len(items) - len(todo), "labeled": 0, "failed": [],
              "batches": 0, "input_tokens": 0, "output_tokens": 0, "list_cost_usd": 0.0, "cost_usd": 0.0,
              "budget_usd": budget_usd, "budget_exhausted": False, "model": MODEL, "agent": AGENT}
    lock = threading.Lock()
    batches = [todo[n:n + batch_size] for n in range(0, len(todo), batch_size)]

    def run_batch(n, batch):
        pending = list(batch)
        for attempt in range(retries + 1):
            with lock:
                if report["list_cost_usd"] >= budget_usd:
                    report["budget_exhausted"] = True
                    break
            try:
                text, usage = backend(prompt(tax, pending), f"catalog-labels-{tax['digest']}-{n}-{attempt}")
            except TransientError as e:
                log(f"batch {n} attempt {attempt + 1}: {e}")
                time.sleep(backoff * (2 ** attempt))
                continue
            with lock:
                report["batches"] += 1
                for k, rk in (("input_tokens", "input_tokens"), ("output_tokens", "output_tokens"),
                              ("list_cost", "list_cost_usd"), ("cost", "cost_usd")):
                    report[rk] += usage.get(k, 0)
            try:
                answer = parse_answer(text)
            except TransientError as e:
                log(f"batch {n} attempt {attempt + 1}: {e}")
                continue
            left = []
            with lock:
                for item in pending:
                    got = answer.get(item["id"])
                    if not isinstance(got, dict):
                        left.append(item)
                        continue
                    labels, rejected = validate(got.get("labels"), tax)
                    cache[cache_key(item, tax)] = {
                        "id": item["id"], "labels": labels, "rejected": rejected,
                        "reason": str(got.get("reason") or "")[:200], "model": MODEL,
                    }
                    report["labeled"] += 1
                dump_json(cache_path, cache)
            pending = left
            if not pending:
                break
        with lock:
            report["failed"].extend(i["id"] for i in pending)

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
        list(pool.map(lambda nb: run_batch(*nb), enumerate(batches)))
    report["list_cost_usd"] = round(report["list_cost_usd"], 4)
    report["cost_usd"] = round(report["cost_usd"], 4)
    report["failed"].sort()
    return report, cache


def proposals(items, tax, cache):
    """app id -> labels (derived merged over the model's) + one-line reason, for review."""
    out = {}
    for item in items:
        hit = cache.get(cache_key(item, tax))
        if hit is None:
            continue
        labels = dict(hit["labels"])
        labels.update(derived(item))
        entry = {"labels": dict(sorted(labels.items())), "reason": hit["reason"], "kind": item["kind"],
                 "digest": item["digest"], "path": item["path"]}
        if hit.get("rejected"):
            entry["rejected"] = hit["rejected"]
        out[item["id"]] = entry
    return dict(sorted(out.items()))


FORMATS = [
    dict(indent=2, sort_keys=True, ensure_ascii=False),
    dict(indent=1, sort_keys=True, ensure_ascii=False),
    dict(indent=2, ensure_ascii=False),
    dict(indent=1, ensure_ascii=False),
]


def write_labels(path, labels):
    """Set manifest.metadata.labels in a payload file, keeping its JSON formatting."""
    path = pathlib.Path(path)
    original = path.read_text()
    data = json.loads(original)
    fmt = next((f for f in FORMATS for nl in ("\n", "") if json.dumps(data, **f) + nl == original), FORMATS[0])
    newline = "\n" if original.endswith("\n") else ""
    meta = data.setdefault("manifest", {}).setdefault("metadata", {})
    if meta.get("labels") == labels:
        return False
    meta["labels"] = labels
    path.write_text(json.dumps(data, **fmt) + newline)
    return True


def apply(items, props, catalog=CATALOG):
    """Draft payloads get metadata.labels; published bundles go to the re-sign worklist."""
    catalog = pathlib.Path(catalog)
    changed, resign = [], []
    for item in items:
        p = props.get(item["id"])
        if not p:
            continue
        if item["kind"] == "published":
            resign.append({"id": item["id"], "signed_digest": item.get("signed_digest"),
                           "source": item["source"], "labels": p["labels"],
                           "set": "manifest.metadata.labels"})
        elif write_labels(catalog / item["path"], p["labels"]):
            changed.append(item["id"])
    return changed, resign


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["propose", "apply", "check"])
    ap.add_argument("--catalog", default=str(CATALOG))
    ap.add_argument("--batch", type=int, default=25)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--budget-usd", type=float, default=15.0, help="stop at this list-price spend")
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--profile", default=os.environ.get("RAGENTIC_PROFILE"))
    ap.add_argument("--limit", type=int, default=0, help="only the first N uncached items (trial runs)")
    args = ap.parse_args(argv)

    catalog = pathlib.Path(args.catalog)
    labels_dir = catalog / "labels"
    tax = load_taxonomy(labels_dir / "taxonomy.json")
    items = collect(catalog)

    if args.command == "propose":
        cache_path = labels_dir / "cache.json"
        todo = items
        if args.limit:
            cache = load_json(cache_path, {})
            todo = [i for i in items if cache_key(i, tax) not in cache][:args.limit]
        report, cache = propose(todo, tax, AgentBackend(profile=args.profile), cache_path,
                                batch_size=args.batch, concurrency=args.concurrency,
                                budget_usd=args.budget_usd, retries=args.retries)
        props = proposals(items, tax, cache)
        dump_json(labels_dir / "proposals.json", props)
        report["proposals"] = len(props)
        report["unlabeled"] = sorted(i["id"] for i in items if i["id"] not in props)
        dump_json(labels_dir / "last-run.json", report)
        print(json.dumps({k: v for k, v in report.items() if k != "unlabeled"}, indent=2))
        return 1 if report["failed"] else 0

    props = load_json(labels_dir / "proposals.json", {})
    errors = [f"{app}: {e}" for app, p in props.items() for e in check_labels(p["labels"], tax)]
    if args.command == "check":
        missing = [i["id"] for i in items if i["id"] not in props]
        stale = [i["id"] for i in items if i["id"] in props and props[i["id"]]["digest"] != i["digest"]]
        for e in errors:
            print(e)
        print(f"{len(props)} proposals, {len(errors)} invalid, {len(missing)} missing, {len(stale)} stale")
        return 1 if errors else 0
    if errors:
        print("\n".join(errors))
        return 1
    changed, resign = apply(items, props, catalog)
    dump_json(labels_dir / "resign.json", {
        "note": "Published bundles are signed: set manifest.metadata.labels in each source, then run the Sign "
                "workflow (mix catalog.sign). See catalog/drafts/PUBLISHING.md, 'Labels'.",
        "taxonomy_version": tax["version"],
        "apps": resign,
    })
    print(f"labels written to {len(changed)} draft payloads; {len(resign)} published apps in resign.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
