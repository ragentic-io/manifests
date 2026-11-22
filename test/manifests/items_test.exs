defmodule Manifests.ItemsTest do
  use ExUnit.Case, async: true

  alias Manifests.{CatalogFixture, Items}
  alias Manifests.CatalogTools.Catalog
  alias Manifests.Items.{AgencyAgents, AgencyRoles, Importer, RagenticExamples, Sign, Validate}

  @moduletag :tmp_dir
  @seed :crypto.hash(:sha256, "items test key")
  @fixture Path.expand("../fixtures/agency-mini", __DIR__)

  defp payload(overrides \\ %{}) do
    CatalogFixture.item_payload(%{id: "designer", version: "1.0.0"}, 0)
    |> Map.drop(~w(not_before expires))
    |> Map.merge(overrides)
  end

  describe "validate" do
    test "a well-formed item passes" do
      assert Validate.check(payload(), categories: ["ai"]) == []
    end

    test "an Agent with spec.model, a forbidden kind, a missing models entry and a secret are refused" do
      [agent] = payload()["manifests"]

      bad =
        payload(%{
          "manifests" => [
            put_in(agent, ["spec", "model"], "eng-1/opus"),
            %{"kind" => "Credential", "metadata" => %{"name" => "key"}, "spec" => %{}},
            %{
              "kind" => "Agent",
              "metadata" => %{"name" => "other"},
              "spec" => %{"system" => "ghp_" <> String.duplicate("a", 36)}
            }
          ]
        })

      errors = Enum.join(Validate.check(bad, categories: ["ai"]), "\n")
      assert errors =~ "an Agent carries no spec.model"
      assert errors =~ "kind Credential never ships in an item"
      assert errors =~ "Agent other has no suggested model"
      assert errors =~ "looks like a real credential"
    end

    test "tiers, categories, kinds and Team references are checked" do
      bad =
        payload(%{
          "models" => %{"designer" => %{"tier" => "huge"}},
          "item" =>
            Map.merge(payload()["item"], %{"kind" => "Workflow", "categories" => ["nope"]})
        })

      errors = Enum.join(Validate.check(bad, categories: ["ai"]), "\n")
      assert errors =~ "tier must be large, medium or small"
      assert errors =~ "unknown category \"nope\""
      assert errors =~ "item.kind Workflow is none of its manifests' kinds"

      team = %{
        "kind" => "Team",
        "metadata" => %{"name" => "t"},
        "spec" => %{"lead" => "ghost", "members" => ["designer"]}
      }

      bad =
        payload(%{
          "manifests" => payload()["manifests"] ++ [team],
          "item" => Map.put(payload()["item"], "kind", "Team")
        })

      assert Enum.join(Validate.check(bad, categories: ["ai"]), "\n") =~
               "names ghost, which is not an Agent"
    end

    test "an id taken by an application is refused" do
      assert Enum.join(Validate.check(payload(), app_ids: ["designer"]), "\n") =~
               "already an application's"
    end
  end

  describe "sign" do
    setup %{tmp_dir: tmp} do
      File.write!(
        Path.join(tmp, "registry.json"),
        JSON.encode!(%{
          "registry" => "manifests.ragentic.io",
          "root" => Base.url_encode64(public(), padding: false),
          "validity_days" => 90,
          "refresh_days" => 21
        })
      )

      File.write!(Path.join(tmp, "categories.json"), ~s([{"id": "ai", "title": "AI"}]))
      Items.write!(Catalog.new(tmp), Map.put(payload(), "version", "1.0.0"))
      %{c: Catalog.new(tmp)}
    end

    test "signs items into item-bundles/ and a verified items index, then nothing is pending", %{
      c: c
    } do
      now = System.system_time(:second)
      assert %{"designer" => ["not signed yet"]} = Validate.run(c, now: now).waiting

      plan = Sign.run(c, key: @seed, now: now)
      assert Map.keys(plan) == ["designer"]

      envelope = c |> Catalog.path("items-index.json") |> File.read!() |> JSON.decode!()

      assert {:ok, %{"sequence" => 1, "entries" => [entry]}} =
               Manifests.Trust.verify_index(envelope, public(), "manifests.ragentic.io", 0,
                 catalog_kind: "items_index"
               )

      assert %{"id" => "designer", "kind" => "Agent", "tiers" => ["large+tools"], "count" => 1} =
               entry

      bundle = c |> Items.bundle_path(entry["digest"]) |> File.read!() |> JSON.decode!()
      expected = %{id: "designer", version: "1.0.0", digest: entry["digest"]}

      assert {:ok, %{"kind" => "item", "manifests" => [_]}} =
               Manifests.Trust.verify_item(bundle, public(), expected)

      # an app-only consumer refuses the items index: the two never mix
      assert {:error, :untrusted_index} =
               Manifests.Trust.verify_index(envelope, public(), "manifests.ragentic.io", 0)

      assert %{errors: [], waiting: waiting} = Validate.run(c, now: now)
      assert waiting == %{}

      # unchanged sources: re-signing changes nothing
      assert Sign.run(c, key: @seed, now: now + 10) == %{}
    end
  end

  defp public, do: elem(:crypto.generate_key(:eddsa, :ed25519, @seed), 0)

  describe "versions" do
    test "bump by what changed" do
      old = Map.put(payload(), "version", "1.2.3")
      [agent] = old["manifests"]

      assert Importer.version(nil, payload()) == "1.0.0"
      assert Importer.version(old, payload()) == "1.2.3"

      assert Importer.version(
               old,
               payload(%{"manifests" => [put_in(agent, ["spec", "system"], "new prompt")]})
             ) == "1.2.4"

      assert Importer.version(
               old,
               payload(%{"models" => %{"designer" => %{"tier" => "medium", "tools" => true}}})
             ) == "1.3.0"

      extra = %{agent | "metadata" => %{"name" => "two"}}
      assert Importer.version(old, payload(%{"manifests" => [agent, extra]})) == "1.3.0"
      assert Importer.version(old, payload(%{"manifests" => [extra]})) == "2.0.0"
    end
  end

  describe "agency-agents" do
    defp fixture_files do
      dir = Path.join(@fixture, "roles")

      for p <- Path.wildcard(Path.join(dir, "**/*.md")),
          do: {Path.relative_to(p, dir), File.read!(p)}
    end

    test "the conversion equals the shared fixture (kept equal to ragentic's TeamSource)" do
      roles =
        for {path, bytes} <- Enum.sort(fixture_files()),
            {:ok, r} <- [AgencyRoles.parse(path, bytes)],
            do: r

      cfg = %{"leads" => %{"engineering" => "engineering-software-architect"}}
      plan = AgencyAgents.plan(roles, cfg, "agency")
      expected = @fixture |> Path.join("expected.json") |> File.read!() |> JSON.decode!()
      assert %{"agents" => plan.agents, "teams" => plan.teams} == expected
    end

    test "one Agent item per role and one Team item per division, tiers from the reviewed config" do
      cfg = AgencyAgents.config(Catalog.new(Path.expand("../../catalog", __DIR__)))
      examples = Importer.model_examples(Catalog.new(Path.expand("../../catalog", __DIR__)))
      items = AgencyAgents.payloads(fixture_files(), cfg, examples, String.duplicate("a", 40))

      assert Enum.map(items, & &1["id"]) == [
               "agency-design-ui-designer",
               "agency-engineering-frontend-developer",
               "agency-engineering-software-architect",
               "agency-team-design",
               "agency-team-engineering"
             ]

      by_id = Map.new(items, &{&1["id"], &1})

      assert %{"tier" => "large", "tools" => true} =
               by_id["agency-engineering-software-architect"]["models"][
                 "engineering-software-architect"
               ]

      assert %{"tier" => "medium", "vision" => true} =
               by_id["agency-design-ui-designer"]["models"]["design-ui-designer"]

      assert get_in(by_id["agency-engineering-frontend-developer"], [
               "manifests",
               Access.at(0),
               "spec",
               "tools"
             ]) == ["graph", "context"]

      team = by_id["agency-team-design"]
      assert team["item"]["kind"] == "Team"
      assert Enum.map(team["manifests"], & &1["kind"]) == ["Agent", "Agent", "Team"]
      assert team["rights"]["license"] == "MIT"
      assert Enum.all?(items, &(Validate.check(Map.put(&1, "version", "1.0.0")) == []))
    end
  end

  describe "ragentic examples" do
    test "drops the example's model, strips listed kinds and refuses unlisted forbidden ones" do
      yaml = """
      kind: ModelProvider
      metadata: {name: claude-max}
      spec: {api: claude-code}
      ---
      kind: Agent
      metadata: {name: designer, namespace: ops}
      spec: {model: claude-max/opus, fallback: [x/y], system: hi}
      """

      entry = %{
        "path" => "examples/x.yaml",
        "id" => "designer",
        "title" => "Designer",
        "description" => "d",
        "categories" => ["ai"],
        "strip" => ["ModelProvider"],
        "models" => %{"designer" => %{"tier" => "large", "tools" => true}}
      }

      cfg = %{"repository" => "ragentic-io/ragentic", "license" => "PolyForm-Noncommercial-1.0.0"}
      examples = %{"tiers" => %{"large" => %{"anthropic" => ["claude-opus-5-5"]}}}
      p = RagenticExamples.payload(entry, yaml, cfg, examples, "abc")

      assert [%{"kind" => "Agent", "spec" => %{"system" => "hi"} = spec}] = p["manifests"]
      refute Map.has_key?(spec, "model") or Map.has_key?(spec, "fallback")
      assert p["item"]["kind"] == "Agent"
      assert p["models"]["designer"]["examples"] == %{"anthropic" => ["claude-opus-5-5"]}
      assert p["item"]["params"]["workspace"]["default"] == "ops"

      assert_raise RuntimeError, ~r/holds ModelProvider/, fn ->
        RagenticExamples.payload(Map.delete(entry, "strip"), yaml, cfg, examples, "abc")
      end
    end
  end
end
