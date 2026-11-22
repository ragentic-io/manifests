defmodule Manifests.Items.Validate do
  @moduledoc """
  The rules an item must meet before it is signed (docs/registry.md, 1.1), and
  the check of the signed items index and bundles against the pinned root.

  - `manifests` hold only kinds an item may install: every ragentic kind except
    `Credential`, `Identity`, `Authority`, `Person`, `Middleware` and
    `ModelProvider`. No secret, credential or grant ever ships in an item.
  - An Agent never carries `spec.model` or `spec.fallback`; every Agent has a
    `models` entry and every `models` key is an Agent of the item.
  - A suggested model has `tier` large | medium | small and optional `tools`,
    `vision` (booleans), `minContextTokens`, `why` and `examples`.
  - A Team's lead and members resolve inside the item (or the item names the
    items it requires).
  - No credential-like strings anywhere.
  """

  alias Manifests.CatalogTools.{Catalog, Json, Trust}
  alias Manifests.Items

  # the kinds of ragentic (Ragentic.Kind) and the old names apply still accepts
  @kinds ~w(Agent Asset BlockTemplate Board Capability CatalogSource ChatBinding ChatBot
            Component Connector ConnectorTemplate Controller Definition Diagram Extractor
            Glider Goal Index IndexProfile Model NeedleDataset NeedleModel Operator Package
            Page Persona PlcSimulator Repository Route Rule Runtime Schema Site Stream Team
            TeamSource Term Tool Unit Workflow Workspace App DataConnector Pipeline)
  @forbidden ~w(Credential Identity Authority Person Middleware ModelProvider)
  @tiers ~w(large medium small)
  @id ~r/\A[a-z0-9][a-z0-9._-]{0,127}\z/
  @name ~r/\A[a-z0-9]([-a-z0-9.]{0,61}[a-z0-9])?\z/
  @semver ~r/\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\z/
  @secret ~r/sk_live_[0-9A-Za-z]{16,}|sk-ant-[0-9A-Za-z_-]{20,}|sk-[A-Za-z0-9]{32,}|gh[pousr]_[0-9A-Za-z]{30,}|xox[abpr]-[0-9A-Za-z-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----\s*[A-Za-z0-9+\/=]{64}/

  def kinds, do: @kinds
  def forbidden_kinds, do: @forbidden
  def tiers, do: @tiers

  @doc "Problems with one item payload (empty when it may be signed)."
  def check(payload, opts \\ []) do
    categories = Keyword.get(opts, :categories)
    app_ids = Keyword.get(opts, :app_ids, [])
    item = payload["item"]
    manifests = payload["manifests"]
    models = payload["models"] || %{}

    errors =
      [
        need(
          is_binary(payload["id"]) and Regex.match?(@id, payload["id"]),
          "id must match #{inspect(@id.source)}"
        ),
        need(payload["id"] not in app_ids, "id #{payload["id"]} is already an application's"),
        need(
          is_binary(payload["version"]) and Regex.match?(@semver, payload["version"]),
          "version must be semver (1.2.3)"
        ),
        need(is_map(item), "item must be an object"),
        need(
          is_list(manifests) and length(manifests) in 1..200,
          "manifests must hold 1 to 200 manifests"
        ),
        need(is_map(models), "models must be an object"),
        need(is_map(payload["provenance"] || %{}), "provenance must be an object"),
        need(
          is_map(payload["rights"]) and is_binary(payload["rights"]["license"]),
          "rights.license is required"
        )
      ] ++ item_errors(item, manifests, categories)

    errors =
      if is_list(manifests) and is_map(models),
        do: errors ++ manifest_errors(manifests, payload) ++ model_errors(manifests, models),
        else: errors

    errors = errors ++ secrets(payload, "")
    Enum.reject(errors, &is_nil/1)
  end

  defp need(true, _), do: nil
  defp need(_, msg), do: msg

  defp item_errors(item, manifests, categories) when is_map(item) do
    kinds =
      if is_list(manifests), do: manifests |> Enum.map(& &1["kind"]) |> Enum.uniq(), else: []

    cats = item["categories"]

    [
      need(
        is_binary(item["kind"]) and Regex.match?(~r/\A[A-Z][A-Za-z0-9]{0,63}\z/, item["kind"]),
        "item.kind must be a kind name"
      ),
      need(
        item["kind"] == "Bundle" or item["kind"] in kinds,
        "item.kind #{item["kind"]} is none of its manifests' kinds (use Bundle for a mix)"
      ),
      need(
        item["kind"] != "Bundle" or length(kinds) > 1,
        "item.kind Bundle is for a mix of kinds"
      ),
      need(
        is_binary(item["title"]) and byte_size(item["title"]) in 1..256,
        "item.title is required (at most 256 bytes)"
      ),
      need(
        is_binary(item["description"]) and byte_size(item["description"]) in 1..2000,
        "item.description is required (at most 2000 bytes)"
      ),
      need(
        is_binary(item["publisher"]) and
          Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,63}\z/, item["publisher"]),
        "item.publisher is required"
      ),
      need(is_list(cats) and length(cats) in 1..4, "item.categories lists 1 to 4 ids"),
      need(
        strings?(item["keywords"] || [], 32, 64),
        "item.keywords: at most 32 strings of 64 bytes"
      ),
      need(strings?(item["provides"] || [], 32, 256), "item.provides: at most 32 strings"),
      need(is_map(item["requires"] || %{}), "item.requires must be an object"),
      need(is_map(item["params"] || %{}), "item.params must be an object"),
      need(
        is_nil(item["logo"]) or
          (is_binary(item["logo"]) and String.starts_with?(item["logo"], "https://")),
        "item.logo must be an https URL"
      )
    ] ++
      if is_list(cats) and categories != nil do
        for c <- cats,
            c not in categories,
            do: "item.categories: unknown category #{inspect(c)} (categories.json)"
      else
        []
      end
  end

  defp item_errors(_, _, _), do: []

  defp strings?(list, max, size),
    do:
      is_list(list) and length(list) <= max and
        Enum.all?(list, &(is_binary(&1) and byte_size(&1) in 1..size))

  defp manifest_errors(manifests, payload) do
    refs = Enum.map(manifests, &ref/1)

    dupes =
      refs
      |> Enum.frequencies()
      |> Enum.filter(fn {_, n} -> n > 1 end)
      |> Enum.map(fn {r, _} -> "manifests: #{r} appears twice" end)

    agent_names =
      payload["manifests"] |> Items.agents() |> MapSet.new(&get_in(&1, ["metadata", "name"]))

    requires_items? = (get_in(payload, ["item", "requires", "items"]) || []) != []

    dupes ++
      Enum.flat_map(Enum.with_index(manifests), fn {doc, i} ->
        doc_errors(doc, "manifests[#{i}]", agent_names, requires_items?)
      end)
  end

  defp doc_errors(doc, where, agent_names, requires_items?) when is_map(doc) do
    kind = doc["kind"]
    meta = doc["metadata"]
    spec = doc["spec"] || %{}

    base = [
      need(is_binary(kind), "#{where}: kind is required"),
      need(
        kind not in @forbidden,
        "#{where}: kind #{kind} never ships in an item (credentials, identities and model providers are the installer's)"
      ),
      need(kind in @forbidden or kind in @kinds, "#{where}: unknown kind #{inspect(kind)}"),
      need(
        is_map(meta) and is_binary(meta["name"]) and Regex.match?(@name, meta["name"]),
        "#{where}: metadata.name must be a manifest name"
      ),
      need(is_map(spec), "#{where}: spec must be an object")
    ]

    kind_errors =
      case kind do
        "Agent" ->
          [
            need(
              not Map.has_key?(spec, "model"),
              "#{where}: an Agent carries no spec.model (install maps its suggested tier)"
            ),
            need(
              not Map.has_key?(spec, "fallback"),
              "#{where}: an Agent carries no spec.fallback"
            )
          ]

        "Team" when not requires_items? ->
          names = [spec["lead"] | List.wrap(spec["members"])] |> Enum.filter(&is_binary/1)

          for n <- names,
              not MapSet.member?(agent_names, n),
              do: "#{where}: Team #{meta["name"]} names #{n}, which is not an Agent of the item"

        "Package" ->
          inner = spec["manifests"] || []

          Enum.flat_map(Enum.with_index(inner), fn {d, j} ->
            if d["kind"] == "Package",
              do: ["#{where}.spec.manifests[#{j}]: no Package inside a Package"],
              else: doc_errors(d, "#{where}.spec.manifests[#{j}]", agent_names, requires_items?)
          end)

        _ ->
          []
      end

    base ++ kind_errors
  end

  defp doc_errors(_, where, _, _), do: ["#{where}: not a manifest"]

  defp ref(doc) when is_map(doc) do
    meta = doc["metadata"] || %{}
    "#{doc["kind"]}/#{meta["namespace"] || "-"}/#{meta["name"]}"
  end

  defp ref(_), do: "?"

  defp model_errors(manifests, models) do
    agents = manifests |> Items.agents() |> Enum.map(&get_in(&1, ["metadata", "name"]))

    missing =
      for a <- agents,
          not Map.has_key?(models, a),
          do: "models: Agent #{a} has no suggested model"

    extra = for {k, _} <- models, k not in agents, do: "models: #{k} is not an Agent of the item"

    shape =
      Enum.flat_map(models, fn {k, m} ->
        if is_map(m) do
          [
            need(m["tier"] in @tiers, "models.#{k}.tier must be large, medium or small"),
            need(
              is_nil(m["tools"]) or is_boolean(m["tools"]),
              "models.#{k}.tools must be true or false"
            ),
            need(
              is_nil(m["vision"]) or is_boolean(m["vision"]),
              "models.#{k}.vision must be true or false"
            ),
            need(
              is_nil(m["minContextTokens"]) or
                (is_integer(m["minContextTokens"]) and m["minContextTokens"] > 0),
              "models.#{k}.minContextTokens must be a positive integer"
            ),
            need(is_nil(m["why"]) or is_binary(m["why"]), "models.#{k}.why must be text"),
            need(examples?(m["examples"]), "models.#{k}.examples maps a vendor to model names")
          ]
        else
          ["models.#{k} must be an object"]
        end
      end)

    missing ++ extra ++ shape
  end

  defp examples?(nil), do: true

  defp examples?(m) when is_map(m),
    do: Enum.all?(m, fn {k, v} -> is_binary(k) and strings?(v, 16, 128) end)

  defp examples?(_), do: false

  defp secrets(v, where) when is_map(v),
    do: Enum.flat_map(v, fn {k, x} -> secrets(x, "#{where}.#{k}") end)

  defp secrets(v, where) when is_list(v),
    do: v |> Enum.with_index() |> Enum.flat_map(fn {x, i} -> secrets(x, "#{where}[#{i}]") end)

  defp secrets(v, where) when is_binary(v) do
    if Regex.match?(@secret, v),
      do: ["#{String.trim_leading(where, ".")} looks like a real credential"],
      else: []
  end

  defp secrets(_, _), do: []

  ## The catalog

  @doc """
  Check every item's sources and the signed items index: `%{errors: [...],
  waiting: %{id => [reason]}, stale: [path]}`. `waiting` are items whose
  sources differ from what is signed (the Sign workflow signs them).
  """
  def run(c, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    cfg = Catalog.config(c)
    refresh = Json.fetch!(cfg, "refresh_days") * 86_400
    categories = c |> Catalog.categories() |> Json.keys()
    app_ids = Catalog.app_ids(c)
    {signed_errors, signed} = check_signed(c, cfg, now)

    results =
      for id <- Items.ids(c) do
        try do
          payload = Items.load(c, id)
          errors = check(payload, categories: categories, app_ids: app_ids)

          errors =
            errors ++
              if(payload["id"] != id,
                do: ["id #{payload["id"]} differs from its folder"],
                else: []
              )

          errors = Enum.map(errors, &"items/#{id}: #{&1}")

          listing = Path.join(Items.item_dir(c, id), "ITEM.md")

          stale =
            if File.exists?(listing) and File.read!(listing) == Items.render_listing(payload),
              do: [],
              else: ["items/#{id}/ITEM.md"]

          {id, errors, pending(payload, Map.get(signed, id), now, refresh), stale}
        rescue
          e -> {id, ["items/#{id}: unreadable sources (#{Exception.message(e)})"], [], []}
        end
      end

    ids = Items.ids(c)

    removed =
      for {id, _} <- signed,
          id not in ids,
          into: %{},
          do: {id, ["removed from items/; will be unpublished"]}

    %{
      errors: signed_errors ++ Enum.flat_map(results, &elem(&1, 1)),
      waiting:
        results
        |> Enum.reject(fn {_, _, reasons, _} -> reasons == [] end)
        |> Map.new(fn {id, _, reasons, _} -> {id, reasons} end)
        |> Map.merge(removed),
      stale: Enum.flat_map(results, &elem(&1, 3))
    }
  end

  @doc "Print the items part of `mix catalog.validate`; `:ok` or `{:error, 1}`."
  def report(c, opts \\ []) do
    %{errors: errors, waiting: waiting, stale: stale} = run(c, opts)
    n = length(Items.ids(c))

    IO.puts(
      "#{n} items, #{n - map_size(waiting)} signed and current, #{map_size(waiting)} waiting for signature"
    )

    waiting
    |> Enum.sort()
    |> Enum.take(50)
    |> Enum.each(fn {id, reasons} -> IO.puts("  pending  #{id}: #{Enum.join(reasons, "; ")}") end)

    errors =
      errors ++
        if(stale != [],
          do: [
            "generated listings are out of date: #{Enum.join(Enum.take(stale, 10), ", ")}; re-run the importer or `mix catalog.items.docs`"
          ],
          else: []
        ) ++
        if(Keyword.get(opts, :require_signed) && map_size(waiting) > 0,
          do: ["#{map_size(waiting)} items are not signed"],
          else: []
        )

    Enum.each(errors, &IO.puts("ERROR #{&1}"))

    if errors == [] do
      IO.puts("items ok")
      :ok
    else
      {:error, 1}
    end
  end

  @doc "Why an item needs signing (empty when its signed bundle is current)."
  def pending(_payload, nil, _now, _refresh), do: ["not signed yet"]

  def pending(payload, %{payload: signed}, now, refresh) do
    cond do
      signed == nil -> ["bundle missing"]
      not Items.same?(signed, payload) -> ["sources changed"]
      signed["expires"] - now < refresh -> ["signature expires soon"]
      true -> []
    end
  end

  # Verify items-index.json and each bundle it names against the pinned root.
  defp check_signed(c, cfg, now) do
    path = Catalog.path(c, Items.index_file())

    if File.exists?(path) do
      root = cfg |> Json.fetch!("root") |> Trust.b64d()
      registry = Json.fetch!(cfg, "registry")
      envelope = path |> File.read!() |> JSON.decode!()

      case Manifests.Trust.verify_index(envelope, root, registry, 0,
             now: now,
             catalog_kind: "items_index"
           ) do
        {:ok, index} ->
          Enum.reduce(index["entries"], {[], %{}}, fn entry, {errors, signed} ->
            expected = %{id: entry["id"], version: entry["version"], digest: entry["digest"]}

            with {:ok, bytes} <- File.read(Items.bundle_path(c, entry["digest"])),
                 {:ok, payload} <-
                   Manifests.Trust.verify_item(JSON.decode!(bytes), root, expected, now: now),
                 true <- Items.index_entry(payload, entry["digest"]) == entry do
              {errors, Map.put(signed, entry["id"], %{entry: entry, payload: payload})}
            else
              _ ->
                {errors ++
                   ["items-index.json: #{entry["id"]}@#{entry["version"]} does not verify"],
                 Map.put(signed, entry["id"], %{entry: entry, payload: nil})}
            end
          end)

        {:error, reason} ->
          {["items-index.json: #{reason}"], %{}}
      end
    else
      {[], %{}}
    end
  end
end
