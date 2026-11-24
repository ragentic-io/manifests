defmodule Manifests.Items do
  @moduledoc """
  Items: anything that is a ragentic manifest, preconfigured — an Agent, a Team
  with its agents, Workflows, a Site with its Pages, a Package — as one signed
  bundle (docs/registry.md in ragentic, section 1).

  Sources live in `catalog/items/<id>/`:

    * `item.json` — everything but the manifests: `id`, `version`, `item`
      (kind, title, description, categories, keywords, publisher, provides,
      requires, params), `models` (one suggested model per Agent), `provenance`
      and `rights`;
    * `manifests.yaml` — the manifests, as multi-document YAML;
    * `ITEM.md` — the generated listing (`render_listing/1`).

  Signed objects: `catalog/item-bundles/<digest>.json` (payload kind `item`) and
  `catalog/items-index.json` (kind `items_index`, its own sequence), in the same
  envelope as apps (`Manifests.CatalogTools.Trust`).
  """

  alias Manifests.CatalogTools.{Catalog, Json, Trust}

  @index "items-index.json"
  @bundles "item-bundles"

  def index_file, do: @index
  def bundles_dir, do: @bundles

  def dir(c), do: Catalog.path(c, "items")
  def item_dir(c, id), do: Path.join(dir(c), id)

  @doc "Every item id with a source directory, sorted."
  def ids(c) do
    case File.ls(dir(c)) do
      {:ok, names} ->
        names |> Enum.filter(&File.exists?(Path.join([dir(c), &1, "item.json"]))) |> Enum.sort()

      _ ->
        []
    end
  end

  @doc """
  The unsigned payload of an item from its sources: `item.json` plus
  `manifests` from `manifests.yaml`, with `kind: "item"`. Raises on unreadable
  sources (validate reports them).
  """
  def load(c, id) do
    meta = c |> item_dir(id) |> Path.join("item.json") |> File.read!() |> JSON.decode!()
    manifests = c |> item_dir(id) |> Path.join("manifests.yaml") |> File.read!() |> parse_yaml!()

    meta
    |> Map.drop(~w(kind not_before expires manifests))
    |> Map.put("kind", "item")
    |> Map.put("manifests", manifests)
  end

  @doc "Multi-document YAML to a list of maps (empty documents dropped)."
  def parse_yaml!(text) do
    {:ok, docs} = YamlElixir.read_all_from_string(text)
    Enum.reject(docs, &(&1 in [nil, %{}, ""]))
  end

  @doc "Write an item's sources (`item.json`, `manifests.yaml`, `ITEM.md`) from a payload."
  def write!(c, payload) do
    id = payload["id"]
    path = item_dir(c, id)
    File.mkdir_p!(path)
    meta = Map.drop(payload, ~w(kind manifests not_before expires))
    File.write!(Path.join(path, "item.json"), Json.pretty(meta))
    File.write!(Path.join(path, "manifests.yaml"), to_yaml(payload["manifests"]))
    File.write!(Path.join(path, "ITEM.md"), render_listing(payload))
    :ok
  end

  @doc "Manifests as multi-document YAML (JSON-compatible flow where needed)."
  def to_yaml(docs) do
    Enum.map_join(docs, "", fn doc -> ("---\n" <> Ymlr.document!(doc)) |> strip_doc_marker() end)
  end

  defp strip_doc_marker("---\n---\n" <> rest), do: "---\n" <> rest
  defp strip_doc_marker(text), do: text

  @doc "Every Agent of an item, those inside a Package's `spec.manifests` too."
  def agents(manifests) do
    Enum.flat_map(manifests, fn
      %{"kind" => "Agent"} = doc ->
        [doc]

      %{"kind" => "Package", "spec" => %{"manifests" => inner}} when is_list(inner) ->
        Enum.filter(inner, &match?(%{"kind" => "Agent"}, &1))

      _ ->
        []
    end)
  end

  @doc "A suggested model as a summary: `large+tools`, `medium+vision+tools`, `small`."
  def tier_summary(%{"tier" => tier} = model) do
    Enum.join(
      [tier] ++
        if(model["vision"] == true, do: ["vision"], else: []) ++
        if(model["tools"] == true, do: ["tools"], else: []),
      "+"
    )
  end

  def tier_summary(_), do: nil

  @doc "The items index entry of a payload signed under `digest` (nil fields omitted)."
  def index_entry(payload, digest) do
    item = payload["item"] || %{}

    tiers =
      (payload["models"] || %{})
      |> Map.values()
      |> Enum.map(&tier_summary/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "id" => payload["id"],
      "version" => payload["version"],
      "digest" => digest,
      "kind" => item["kind"],
      "title" => item["title"],
      "description" => item["description"],
      "publisher" => item["publisher"],
      "categories" => item["categories"] || [],
      "keywords" => item["keywords"] || [],
      "provides" => item["provides"] || [],
      "tiers" => tiers,
      "count" => length(payload["manifests"] || []),
      "logo" => item["logo"]
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  ## Signed state

  @doc """
  The signed items index (decoded payload, unverified; `Manifests.Items.Validate`
  verifies it) or nil when there is none.
  """
  def read_index(c) do
    path = Catalog.path(c, @index)

    if File.exists?(path) do
      env = path |> File.read!() |> JSON.decode!()
      env["payload"] |> Trust.b64d() |> JSON.decode!()
    end
  end

  def bundle_path(c, digest), do: Catalog.path(c, Path.join(@bundles, "#{digest}.json"))

  @doc "The decoded payload of a signed item bundle on disk, or nil."
  def bundle_payload(c, digest) do
    with {:ok, bytes} <- File.read(bundle_path(c, digest)),
         %{"envelope" => %{"payload" => p}} <- JSON.decode!(bytes) do
      p |> Trust.b64d() |> JSON.decode!()
    else
      _ -> nil
    end
  end

  @doc "Whether two payloads are the same item content (signing times aside)."
  def same?(a, b), do: content(a) == content(b)

  defp content(p), do: p |> Map.drop(~w(not_before expires)) |> Json.plain()

  ## Listing

  @doc "The generated ITEM.md of a payload."
  def render_listing(payload) do
    item = payload["item"] || %{}
    models = payload["models"] || %{}

    contents =
      Enum.map_join(payload["manifests"] || [], "\n", fn doc ->
        meta = doc["metadata"] || %{}
        ns = if meta["namespace"], do: "#{meta["namespace"]}/", else: ""
        "- #{doc["kind"]} `#{ns}#{meta["name"]}`"
      end)

    agents =
      if models == %{} do
        ""
      else
        rows =
          models
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map_join("\n", fn {name, m} ->
            examples =
              (m["examples"] || %{})
              |> Enum.sort()
              |> Enum.map_join("; ", fn {vendor, list} ->
                "#{vendor}: #{Enum.join(list, ", ")}"
              end)

            "| `#{name}` | #{tier_summary(m)} | #{examples} |"
          end)

        "\n## Suggested models\n\n| agent | tier | examples |\n|---|---|---|\n" <> rows <> "\n"
      end

    provenance = payload["provenance"] || %{}
    rights = payload["rights"] || %{}

    """
    ---
    title: #{JSON.encode!(item["title"])}
    kind: #{JSON.encode!(item["kind"])}
    categories: #{JSON.encode!(item["categories"] || [])}
    ---
    # #{item["title"]}

    #{item["description"]}

    Install: `ragentic install #{payload["id"]}` (version #{payload["version"]}, publisher #{item["publisher"]}).

    ## Contents

    #{contents}
    #{agents}
    ## Source

    #{provenance["repository"]} `#{provenance["path"]}` at `#{provenance["commit"]}`. Licence: #{rights["license"]}#{if rights["attribution"], do: " (" <> rights["attribution"] <> ")", else: ""}.

    _Generated from item.json and manifests.yaml; do not edit._
    """
  end
end
