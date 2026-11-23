"""Tests for label.py: schema validation, caching, resume, retries, budget, apply. No network.

    python3 -I -m unittest discover -s catalog/labels -p 'test_*.py'
"""
import base64
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import label  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent


def b64(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")


def payload(app, protocol="openapi", credential=None, labels=None):
    p = {"app": app, "protocol": protocol, "version": "1",
         "manifest": {"metadata": {"name": app}, "spec": {"base": {"specification": {"document": {
             "info": {"title": app, "description": "An API"}}}}}},
         "graph": {"nodes": [{"kind": "operation", "method": "get", "path": "/things"}]}}
    if credential:
        p["setup"] = {"credential": {"type": credential}}
    if labels is not None:
        p["manifest"]["metadata"]["labels"] = labels
    return p


def make_catalog(root):
    root = pathlib.Path(root)
    (root / "labels").mkdir(parents=True)
    (root / "labels" / "taxonomy.json").write_text((HERE / "taxonomy.json").read_text())
    (root / "categories.json").write_text(json.dumps([{"id": "finance"}, {"id": "social-media"}]))
    for app, cat in (("pay", "drafts"), ("chat", "drafts"), ("shop", "published")):
        d = root / "apps" / app
        d.mkdir(parents=True)
        p = payload(app, credential="static_bearer" if app == "shop" else None)
        (d / "manifest.json").write_text(json.dumps(p, indent=2, sort_keys=True) + "\n")
        (d / "MANIFEST.md").write_text(f'---\ntitle: "{app}"\ncatalog: "{cat}"\ncategories: ["finance"]\n---\nbody\n')
    shop = payload("shop", credential="static_bearer")
    (root / "bundles").mkdir()
    (root / "bundles" / "abc.json").write_text(json.dumps({"chain": [], "envelope": {"payload": b64(shop), "signature": "x"}}))
    (root / "index.json").write_text(json.dumps({"payload": b64({"entries": [{"id": "shop", "digest": "abc"}]}), "signature": "x"}))
    (root / "drafts" / "bluesky").mkdir(parents=True)
    (root / "drafts" / "bluesky" / "payload.json").write_text(json.dumps(payload("bluesky"), indent=1, sort_keys=True) + "\n")
    return root


GOOD = {"category": "finance", "vendor": "acme", "auth": "api-key", "capability": ["read", "payments"],
        "audience": "finance"}


class FakeBackend:
    def __init__(self, answers=None, fail=0, cost=0.3):
        self.calls, self.fail, self.cost, self.answers = 0, fail, cost, answers

    def __call__(self, text, conversation):
        self.calls += 1
        if self.fail:
            self.fail -= 1
            raise label.TransientError("relay hiccup")
        apps = json.loads(text.split("Apps:\n", 1)[1])
        ans = self.answers or {a["id"]: {"labels": GOOD, "reason": "test"} for a in apps}
        return json.dumps(ans), {"input_tokens": 100, "output_tokens": 10, "list_cost": self.cost, "cost": 0}


class ValidationTest(unittest.TestCase):
    def setUp(self):
        self.tax = label.load_taxonomy(HERE / "taxonomy.json")

    def test_accepts_taxonomy_labels_and_flattens_capabilities(self):
        labels, rejected = label.validate(GOOD, self.tax)
        self.assertEqual(rejected, [])
        self.assertEqual(labels["capability.read"], "true")
        self.assertEqual(labels["capability.payments"], "true")
        self.assertEqual(labels["category"], "finance")

    def test_rejects_anything_outside_the_taxonomy(self):
        labels, rejected = label.validate({
            "category": "payments",          # not a categories.json id
            "colour": "blue",                # unknown key
            "auth": "OAuth2",                # wrong case
            "capability": ["read", "teleport"],
            "capability.write": "yes",       # multi keys take "true" only
            "vendor": "Not A Slug!",
            "protocol": "graphql",           # derived: never from the model
            "pricing": 3,
        }, self.tax)
        self.assertEqual(labels, {"capability.read": "true"})
        self.assertIn("category=payments", rejected)
        self.assertIn("colour=blue", rejected)
        self.assertIn("capability.teleport=true", rejected)
        self.assertIn("protocol=graphql", rejected)
        self.assertEqual(len(rejected), 8)

    def test_check_labels_covers_derived_keys(self):
        self.assertEqual(label.check_labels({"protocol": "openapi", "maturity": "draft"}, self.tax), [])
        self.assertTrue(label.check_labels({"maturity": "beta"}, self.tax))

    def test_category_values_come_from_categories_json(self):
        cats = [c["id"] for c in json.loads((HERE.parent / "categories.json").read_text())]
        self.assertEqual(self.tax["keys"]["category"]["values"], cats)


class RunTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = make_catalog(self.dir.name)
        self.tax = label.load_taxonomy(self.root / "labels" / "taxonomy.json")
        self.cache = self.root / "labels" / "cache.json"

    def tearDown(self):
        self.dir.cleanup()

    def run_propose(self, backend, **kw):
        kw.setdefault("backoff", 0)
        return label.propose(label.collect(self.root), self.tax, backend, self.cache, log=lambda *_: None, **kw)

    def test_collects_published_from_signed_bundle_drafts_and_social_drafts(self):
        items = {i["id"]: i for i in label.collect(self.root)}
        self.assertEqual(set(items), {"pay", "chat", "shop", "drafts/bluesky"})
        self.assertEqual(items["shop"]["kind"], "published")
        self.assertEqual(items["shop"]["path"], "bundles/abc.json")
        self.assertEqual(items["drafts/bluesky"]["kind"], "social-draft")

    def test_cached_items_are_not_asked_again(self):
        b = FakeBackend()
        report, _ = self.run_propose(b, batch_size=2)
        self.assertEqual((report["labeled"], b.calls), (4, 2))
        b2 = FakeBackend()
        report, _ = self.run_propose(b2)
        self.assertEqual((report["cached"], report["labeled"], b2.calls), (4, 0, 0))

    def test_only_changed_payloads_are_relabeled(self):
        self.run_propose(FakeBackend())
        mf = self.root / "apps" / "pay" / "manifest.json"
        p = json.loads(mf.read_text())
        p["version"] = "2"
        mf.write_text(json.dumps(p))
        b = FakeBackend()
        report, _ = self.run_propose(b)
        self.assertEqual((report["labeled"], b.calls), (1, 1))

    def test_applied_labels_do_not_change_the_digest(self):
        a = payload("x")
        self.assertEqual(label.payload_digest(a), label.payload_digest(payload("x", labels={"category": "finance"})))
        self.assertNotEqual(label.payload_digest(a), label.payload_digest(payload("y")))

    def test_transient_failures_are_retried(self):
        b = FakeBackend(fail=2)
        report, _ = self.run_propose(b, retries=3)
        self.assertEqual((report["labeled"], report["failed"]), (4, []))

    def test_gives_up_after_retries_and_resumes_later(self):
        report, _ = self.run_propose(FakeBackend(fail=10), retries=1)
        self.assertEqual(len(report["failed"]), 4)
        report, _ = self.run_propose(FakeBackend())
        self.assertEqual(report["labeled"], 4)

    def test_budget_cap_stops_new_calls(self):
        b = FakeBackend(cost=1.0)
        report, _ = self.run_propose(b, batch_size=1, concurrency=1, budget_usd=2.0)
        self.assertEqual(b.calls, 2)
        self.assertTrue(report["budget_exhausted"])
        self.assertEqual(len(report["failed"]), 2)

    def test_missing_answers_are_asked_again(self):
        class Partial(FakeBackend):
            def __call__(self, text, conversation):
                out, usage = super().__call__(text, conversation)
                ans = json.loads(out)
                if self.calls == 1:
                    ans.pop(sorted(ans)[0])
                return json.dumps(ans), usage
        b = Partial()
        report, _ = self.run_propose(b)
        self.assertEqual((report["labeled"], b.calls), (4, 2))

    def test_proposals_merge_derived_labels_over_the_model(self):
        _, cache = self.run_propose(FakeBackend())
        props = label.proposals(label.collect(self.root), self.tax, cache)
        self.assertEqual(props["shop"]["labels"]["auth"], "bearer")  # setup.credential wins
        self.assertEqual(props["shop"]["labels"]["maturity"], "published")
        self.assertEqual(props["pay"]["labels"]["auth"], "api-key")
        self.assertEqual(props["pay"]["labels"]["protocol"], "openapi")
        self.assertEqual(props["pay"]["reason"], "test")

    def test_apply_writes_drafts_and_lists_published_for_resigning(self):
        _, cache = self.run_propose(FakeBackend())
        items = label.collect(self.root)
        props = label.proposals(items, self.tax, cache)
        bundle_before = (self.root / "bundles" / "abc.json").read_text()
        social_before = (self.root / "drafts" / "bluesky" / "payload.json").read_text()
        changed, resign = label.apply(items, props, self.root)
        self.assertEqual(sorted(changed), ["chat", "drafts/bluesky", "pay"])
        self.assertEqual([r["id"] for r in resign], ["shop"])
        self.assertEqual(resign[0]["signed_digest"], "abc")
        self.assertEqual((self.root / "bundles" / "abc.json").read_text(), bundle_before)
        shop = json.loads((self.root / "apps" / "shop" / "manifest.json").read_text())
        self.assertNotIn("labels", shop["manifest"]["metadata"])
        pay = json.loads((self.root / "apps" / "pay" / "manifest.json").read_text())
        self.assertEqual(pay["manifest"]["metadata"]["labels"], props["pay"]["labels"])
        social = (self.root / "drafts" / "bluesky" / "payload.json").read_text()
        self.assertTrue(social.startswith('{\n "'))  # indent=1 kept
        self.assertNotEqual(social, social_before)
        # applying again changes nothing, and the cache still hits
        self.assertEqual(label.apply(label.collect(self.root), props, self.root)[0], [])
        b = FakeBackend()
        self.run_propose(b)
        self.assertEqual(b.calls, 0)

    def test_parse_answer_strips_fences_and_rejects_prose(self):
        self.assertEqual(label.parse_answer('```json\n{"a": 1}\n```'), {"a": 1})
        with self.assertRaises(label.TransientError):
            label.parse_answer("sorry, I cannot")


if __name__ == "__main__":
    unittest.main()
