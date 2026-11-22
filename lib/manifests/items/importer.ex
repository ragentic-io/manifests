defmodule Manifests.Items.Importer do
  @moduledoc """
  What the item importers share (`mix catalog.import agency-agents |
  ragentic-examples`): versions bumped by what changed (docs/registry.md 1.4),
  example models per tier, and writing the items an importer owns.

  Version rule, against the item already in `catalog/items/<id>/`:

    * new item: `1.0.0`;
    * a manifest removed or renamed (it would be pruned on update): MAJOR;
    * a manifest added, or a suggested tier changed: MINOR;
    * any other change (a prompt, a description): PATCH;
    * nothing changed: the version and provenance stay, so a re-run that finds
      the same upstream bytes writes nothing new.
  """

  alias Manifests.CatalogTools.Catalog
  alias Manifests.Items

  @doc "The reviewed example models (`catalog/sources/model-examples.json`)."
  def model_examples(c), do: read_json!(Catalog.path(c, "sources/model-examples.json"))

  def read_json!(path), do: path |> File.read!() |> JSON.decode!()

  @doc """
  A suggested model: `tier`, `tools`, `vision` (only when true), `why` and the
  `examples` of its tier (narrowed to models that see when it needs vision).
  """
  def model(%{"tier" => tier} = spec, examples_cfg) do
    tools = spec["tools"] == true
    vision = spec["vision"] == true

    examples =
      examples_cfg
      |> get_in(["tiers", tier])
      |> Kernel.||(%{})
      |> Map.new(fn {vendor, models} ->
        {vendor, if(vision, do: seeing(vendor, models, examples_cfg), else: models)}
      end)
      |> Map.reject(fn {_, v} -> v == [] end)

    %{"tier" => tier, "tools" => tools, "examples" => examples}
    |> then(&if vision, do: Map.put(&1, "vision", true), else: &1)
    |> then(&if spec["why"], do: Map.put(&1, "why", spec["why"]), else: &1)
    |> then(
      &if is_integer(spec["minContextTokens"]),
        do: Map.put(&1, "minContextTokens", spec["minContextTokens"]),
        else: &1
    )
  end

  defp seeing(vendor, models, cfg) do
    case get_in(cfg, ["vision", vendor]) do
      nil -> models
      list -> Enum.filter(models, &(&1 in list)) |> then(&if(&1 == [], do: list, else: &1))
    end
  end

  @doc "The version `payload` gets, given the item now in the catalog (see moduledoc)."
  def version(nil, _payload), do: "1.0.0"

  def version(old, payload) do
    [major, minor, patch] =
      old["version"]
      |> String.split(["-", "+"])
      |> hd()
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)

    old_refs = refs(old)
    new_refs = refs(payload)

    cond do
      not MapSet.subset?(old_refs, new_refs) -> "#{major + 1}.0.0"
      new_refs != old_refs or tiers(old) != tiers(payload) -> "#{major}.#{minor + 1}.0"
      content(old) != content(payload) -> "#{major}.#{minor}.#{patch + 1}"
      true -> old["version"]
    end
  end

  defp refs(p),
    do: MapSet.new(p["manifests"] || [], &{&1["kind"], get_in(&1, ["metadata", "name"])})

  defp tiers(p), do: Map.new(p["models"] || %{}, fn {k, m} -> {k, Items.tier_summary(m)} end)
  defp content(p), do: Map.drop(p, ~w(version provenance not_before expires))

  @doc """
  Write `payloads` (each without `version`) as items, bumping versions; delete
  the items an importer owned (`owned?.(id)`) that it no longer produces.
  Answers `%{written: n, unchanged: n, removed: [id]}`.
  """
  def write_all(c, payloads, owned?) do
    counts =
      Enum.reduce(payloads, %{written: 0, unchanged: 0}, fn payload, acc ->
        old =
          if File.exists?(Path.join(Items.item_dir(c, payload["id"]), "item.json")),
            do: Items.load(c, payload["id"])

        version = version(old, payload)

        if old && version == old["version"] do
          # same content: keep what is there (provenance too), only the listing is refreshed
          Items.write!(c, old)
          %{acc | unchanged: acc.unchanged + 1}
        else
          Items.write!(c, Map.put(payload, "version", version))
          %{acc | written: acc.written + 1}
        end
      end)

    produced = MapSet.new(payloads, & &1["id"])
    removed = for id <- Items.ids(c), owned?.(id), not MapSet.member?(produced, id), do: id
    Enum.each(removed, &File.rm_rf!(Items.item_dir(c, &1)))
    Map.put(counts, :removed, removed)
  end

  @doc "SHA-256 of bytes, lowercase hex."
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "The commit a git checkout is at, or nil."
  def git_commit(dir) do
    case System.cmd("git", ["-C", dir, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end
end
