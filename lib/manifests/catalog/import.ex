defmodule Manifests.Catalog.Import do
  @moduledoc """
  Loads a signed catalog into the registry. Nothing is written until its
  signature checks out against the pinned root.

  A *source* is a function from a catalog-relative path (`"index.json"`,
  `"bundles/<digest>.json"`, `"apps/<id>/MANIFEST.md"`) to `{:ok, bytes}` or
  `:error`, so the same code reads a directory baked into the image or any
  commit of the catalog's git history.

  Versions are only ever added. The listing (what `latest` means, labels,
  search text) moves forward only: an index with a lower sequence than the one
  already served never replaces it, so a stale image can't roll the catalog back.
  """
  require Logger
  alias Manifests.Registry
  alias Manifests.Registry.{Item, Manifest, Snapshot, Version}
  alias Manifests.Trust

  @kinds [
    {"index", "index.json", "bundles", "published"},
    {"browse_index", "browse-index.json", "browse-bundles", "draft"}
  ]

  @doc """
  Options: `:root` (32-byte key, required), `:registry` (required), `:commit`,
  `:historical` (verify each envelope at the time it was signed instead of now,
  for backfilling git history), `:min_sequence` (`%{"index" => n, ...}`).
  """
  def run(source, opts) do
    results = for kind <- @kinds, do: import_kind(source, kind, opts)

    verified = for {:ok, r} <- results, do: r

    if verified != [] do
      list(source, verified)
    end

    items = import_items(source, opts)
    {:ok, Enum.map(results, &summary/1) ++ [items_summary(items)]}
  end

  @doc "A source reading from a directory on disk."
  def dir(path) do
    fn rel ->
      case File.read(Path.join(path, rel)) do
        {:ok, bytes} -> {:ok, bytes}
        _ -> :error
      end
    end
  end

  @doc "A source reading one commit of a git repository."
  def git(repo, commit) do
    fn rel ->
      case System.cmd("git", ["-C", repo, "show", "#{commit}:#{rel}"], stderr_to_stdout: true) do
        {bytes, 0} -> {:ok, bytes}
        _ -> :error
      end
    end
  end

  defp summary({:ok, r}),
    do: {r.kind, %{sequence: r.sequence, entries: length(r.entries), new: r.new}}

  defp summary({:skip, kind, reason}), do: {kind, reason}

  defp import_kind(source, {kind, file, dir, catalog}, opts) do
    root = Keyword.fetch!(opts, :root)
    registry = Keyword.fetch!(opts, :registry)
    min = opts |> Keyword.get(:min_sequence, %{}) |> Map.get(kind, 0)

    with {:ok, body} <- source.(file) |> or_skip(:missing),
         {:ok, envelope} <- Jason.decode(body) |> or_skip(:not_json),
         now = check_time(envelope, opts),
         {:ok, index} <-
           Trust.verify_index(envelope, root, registry, min, now: now, catalog_kind: kind)
           |> or_skip(:untrusted_index) do
      known = known_digests(Enum.map(index["entries"], & &1["digest"]))

      entries =
        Enum.flat_map(index["entries"], fn entry ->
          record_version(source, dir, catalog, entry, index["sequence"], known, opts)
        end)

      Snapshot
      |> Ash.Changeset.for_create(:record, %{
        kind: kind,
        sequence: index["sequence"],
        body: body,
        entries: length(index["entries"]),
        expires: DateTime.from_unix!(index["expires"]),
        commit: opts[:commit]
      })
      |> Ash.create!()

      {:ok,
       %{
         kind: kind,
         catalog: catalog,
         sequence: index["sequence"],
         entries: entries,
         new: Enum.count(entries, &(not MapSet.member?(known, &1.digest)))
       }}
    else
      {:skip, reason} ->
        Logger.warning("catalog #{kind} #{opts[:commit]}: skipped (#{reason})")
        {:skip, kind, reason}
    end
  end

  defp or_skip({:ok, v}, _), do: {:ok, v}
  defp or_skip(_, reason), do: {:skip, reason}

  # History is verified as of when it was signed; the live catalog as of now.
  defp check_time(envelope, opts) do
    if opts[:historical] do
      with {:ok, bytes} <- Base.url_decode64(envelope["payload"] || "", padding: false),
           {:ok, %{"not_before" => nb}} when is_integer(nb) <- Jason.decode(bytes) do
        nb
      else
        _ -> 0
      end
    else
      Keyword.get(opts, :now, System.system_time(:second))
    end
  end

  defp known_digests(digests) do
    Version
    |> Ash.Query.filter_input(%{digest: %{in: digests}})
    |> Ash.Query.select([:digest])
    |> Ash.read!()
    |> MapSet.new(& &1.digest)
  end

  defp record_version(source, dir, catalog, entry, sequence, known, opts) do
    digest = entry["digest"]
    expected = %{app: entry["id"], version: entry["version"], digest: digest}

    if MapSet.member?(known, digest) do
      # Already verified when first seen; only how recently it was published moves.
      Version
      |> Ash.Query.filter_input(%{digest: %{eq: digest}})
      |> Ash.bulk_update!(:seen, %{catalog: catalog, last_sequence: sequence}, strategy: :atomic)

      [%{entry: entry, digest: digest}]
    else
      with {:ok, body} <- source.("#{dir}/#{digest}.json"),
           {:ok, bundle} <- Jason.decode(body),
           now = bundle_time(bundle, opts),
           {:ok, payload} <- Trust.verify(bundle, opts[:root], expected, now: now),
           true <- payload["protocol"] == entry["protocol"] do
        ensure_manifest(entry, catalog)

        Version
        |> Ash.Changeset.for_create(:record, %{
          manifest_id: entry["id"],
          version: entry["version"],
          digest: digest,
          catalog: catalog,
          protocol: entry["protocol"],
          title: entry["title"],
          readiness: payload["readiness"],
          endpoint: get_in(payload, ["manifest", "spec", "base", "endpoint"]),
          credential: get_in(payload, ["setup", "credential", "type"]),
          bundle: body,
          operations: operations(payload),
          signed_by: Trust.key_id(opts[:root]),
          not_before: DateTime.from_unix!(payload["not_before"]),
          expires: DateTime.from_unix!(payload["expires"]),
          first_sequence: sequence,
          last_sequence: sequence,
          commit: opts[:commit]
        })
        |> Ash.create!()

        [%{entry: entry, digest: digest}]
      else
        other ->
          Logger.warning(
            "bundle #{entry["id"]}@#{entry["version"]} #{digest}: rejected (#{inspect(other)})"
          )

          []
      end
    end
  end

  defp bundle_time(bundle, opts) do
    if opts[:historical],
      do: check_time(bundle["envelope"] || %{}, opts),
      else: check_time(%{}, opts)
  end

  # A version needs its application row to exist; the listing pass fills it in.
  defp ensure_manifest(entry, catalog) do
    case Registry.get_manifest(entry["id"]) do
      {:ok, _} ->
        :ok

      _ ->
        Manifest
        |> Ash.Changeset.for_create(:upsert, %{
          id: entry["id"],
          title: entry["title"],
          protocol: entry["protocol"],
          catalog: catalog,
          latest_version: entry["version"],
          latest_digest: entry["digest"],
          listed: false
        })
        |> Ash.create!()
    end
  end

  @op_fields ~w(name method path summary safe deprecated)
  def operations(payload) do
    for %{"kind" => "operation"} = node <- get_in(payload, ["graph", "nodes"]) || [] do
      node
      |> Map.take(@op_fields)
      |> Map.put("id", node["id"])
      |> Map.update("summary", nil, &truncate/1)
    end
  end

  defp truncate(s) when is_binary(s) and byte_size(s) > 240, do: String.slice(s, 0, 237) <> "…"
  defp truncate(s), do: s

  ## Items of any kind

  # items-index.json and item-bundles/: each bundle verified with Trust.verify_item before it
  # is stored; only an index at least as new as the one served moves the listing.
  defp import_items(source, opts) do
    root = Keyword.fetch!(opts, :root)
    min = opts |> Keyword.get(:min_sequence, %{}) |> Map.get("items_index", 0)

    with {:ok, body} <- source.("items-index.json") |> or_skip(:missing),
         {:ok, envelope} <- Jason.decode(body) |> or_skip(:not_json),
         now = check_time(envelope, opts),
         {:ok, index} <-
           Trust.verify_index(envelope, root, Keyword.fetch!(opts, :registry), min,
             now: now,
             catalog_kind: "items_index"
           )
           |> or_skip(:untrusted_index) do
      current =
        case Registry.latest_snapshot("items_index") do
          {:ok, %{sequence: s}} -> s
          _ -> -1
        end

      fresh? = index["sequence"] >= current
      sequence = index["sequence"]

      stored =
        Enum.flat_map(index["entries"], &record_item(source, &1, sequence, fresh?, opts))

      if fresh? do
        live = MapSet.new(stored)

        Item
        |> Ash.Query.filter_input(%{listed: %{eq: true}})
        |> Ash.read!()
        |> Enum.reject(&MapSet.member?(live, &1.digest))
        |> Enum.each(&(&1 |> Ash.Changeset.for_update(:list, %{listed: false}) |> Ash.update!()))
      end

      Snapshot
      |> Ash.Changeset.for_create(:record, %{
        kind: "items_index",
        sequence: sequence,
        body: body,
        entries: length(index["entries"]),
        expires: DateTime.from_unix!(index["expires"]),
        commit: opts[:commit]
      })
      |> Ash.create!()

      {:ok, %{sequence: sequence, entries: length(stored)}}
    else
      {:skip, reason} -> {:skip, reason}
    end
  end

  defp items_summary({:ok, r}), do: {"items_index", r}
  defp items_summary({:skip, reason}), do: {"items_index", reason}

  defp record_item(source, entry, sequence, false = _fresh?, opts) do
    # an older index than the one served never changes what is listed
    case Registry.item_by_digest(entry["digest"]) do
      {:ok, _} -> [entry["digest"]]
      _ -> record_new_item(source, entry, sequence, false, opts)
    end
  end

  defp record_item(source, entry, sequence, true, opts),
    do: record_new_item(source, entry, sequence, true, opts)

  defp record_new_item(source, entry, sequence, fresh?, opts) do
    digest = entry["digest"]
    expected = %{id: entry["id"], version: entry["version"], digest: digest}

    with {:ok, body} <- source.("item-bundles/#{digest}.json"),
         {:ok, bundle} <- Jason.decode(body),
         now = bundle_time(bundle, opts),
         {:ok, payload} <- Trust.verify_item(bundle, opts[:root], expected, now: now),
         true <- get_in(payload, ["item", "kind"]) == entry["kind"] do
      tiers = List.wrap(entry["tiers"])

      Item
      |> Ash.Changeset.for_create(:record, %{
        item_id: entry["id"],
        version: entry["version"],
        digest: digest,
        kind: entry["kind"],
        title: entry["title"],
        description: entry["description"],
        publisher: entry["publisher"],
        categories: List.wrap(entry["categories"]),
        keywords: List.wrap(entry["keywords"]),
        provides: List.wrap(entry["provides"]),
        tiers: tiers,
        sizes: tiers |> Enum.map(&hd(String.split(&1, "+"))) |> Enum.uniq(),
        count: entry["count"] || length(payload["manifests"] || []),
        logo: entry["logo"],
        bundle: body,
        search_text:
          [entry["id"], entry["title"], entry["description"], entry["kind"], entry["publisher"]]
          |> Kernel.++(List.wrap(entry["keywords"]) ++ List.wrap(entry["categories"]))
          |> Enum.filter(&is_binary/1)
          |> Enum.join(" ")
          |> String.downcase(),
        listed: fresh?,
        signed_by: Trust.key_id(opts[:root]),
        not_before: DateTime.from_unix!(payload["not_before"]),
        expires: DateTime.from_unix!(payload["expires"]),
        first_sequence: sequence,
        last_sequence: sequence,
        commit: opts[:commit]
      })
      |> Ash.create!()

      [digest]
    else
      other ->
        Logger.warning(
          "item #{entry["id"]}@#{entry["version"]} #{digest}: rejected (#{inspect(other)})"
        )

        []
    end
  end

  ## Listing

  defp list(source, verified) do
    categories = categories(source)

    current =
      Map.new(@kinds, fn {kind, _, _, _} ->
        {kind,
         case Registry.latest_snapshot(kind) do
           {:ok, %{sequence: s}} -> s
           _ -> -1
         end}
      end)

    # Only an index at least as new as the one being served may set the listing.
    fresh = Enum.filter(verified, &(&1.sequence >= current[&1.kind]))

    for %{catalog: catalog, entries: entries} <- fresh, %{entry: entry} <- entries do
      upsert_listing(source, entry, catalog, categories)
    end

    if length(fresh) == length(@kinds) do
      listed = for %{entries: es} <- fresh, %{entry: e} <- es, into: MapSet.new(), do: e["id"]
      unlist_missing(listed)
    end

    :ok
  end

  defp upsert_listing(source, entry, catalog, categories) do
    id = entry["id"]
    front = front_matter(source, id)

    version =
      Version
      |> Ash.Query.filter_input(%{digest: %{eq: entry["digest"]}})
      |> Ash.Query.select([:readiness, :endpoint, :credential, :operations])
      |> Ash.read_one!()

    cats = List.wrap(front["categories"])
    endpoint = version.endpoint
    auth = version.credential

    labels =
      Enum.uniq(
        Enum.map(cats, &"category:#{&1}") ++
          ["protocol:#{entry["protocol"]}", "catalog:#{catalog}"] ++
          if(version.readiness, do: ["readiness:#{version.readiness}"], else: []) ++
          if(auth, do: ["auth:#{auth}"], else: []) ++ custom_labels(front["labels"])
      )

    search =
      [id, entry["title"], endpoint | labels]
      |> Kernel.++(Enum.map(cats, &get_in(categories, [&1, "title"])))
      |> Kernel.++(Enum.flat_map(version.operations, &[&1["name"], &1["path"]]))
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    Manifest
    |> Ash.Changeset.for_create(:upsert, %{
      id: id,
      title: front["title"] || entry["title"],
      protocol: entry["protocol"],
      catalog: catalog,
      labels: labels,
      description: front["description"],
      endpoint: endpoint,
      logo: front["logo"],
      latest_version: entry["version"],
      latest_digest: entry["digest"],
      operation_count: length(version.operations),
      search_text: search,
      listed: true
    })
    |> Ash.create!()
  end

  defp unlist_missing(listed) do
    Manifest
    |> Ash.Query.filter_input(%{listed: %{eq: true}})
    |> Ash.read!()
    |> Enum.reject(&MapSet.member?(listed, &1.id))
    |> Enum.each(&(&1 |> Ash.Changeset.for_update(:unlist) |> Ash.update!()))
  end

  @doc "The decoded payload of a stored version's signed bundle."
  def payload(%{bundle: bundle}) do
    with {:ok, %{"envelope" => %{"payload" => p}}} <- Jason.decode(bundle),
         {:ok, bytes} <- Base.url_decode64(p, padding: false),
         {:ok, payload} <- Jason.decode(bytes) do
      payload
    else
      _ -> %{}
    end
  end

  defp custom_labels(labels) when is_map(labels),
    do: Enum.map(labels, fn {k, v} -> "#{k}:#{v}" end)

  defp custom_labels(labels) when is_list(labels),
    do:
      for(l <- labels, is_binary(l), do: if(String.contains?(l, ":"), do: l, else: "label:#{l}"))

  defp custom_labels(_), do: []

  defp categories(source) do
    with {:ok, body} <- source.("categories.json"), {:ok, list} <- Jason.decode(body) do
      Map.new(list, &{&1["id"], &1})
    else
      _ -> %{}
    end
  end

  @doc "The `key: <json>` front matter of an application's MANIFEST.md."
  def front_matter(source, id) do
    case source.("apps/#{id}/MANIFEST.md") do
      {:ok, body} -> parse_front_matter(body)
      :error -> %{}
    end
  end

  def parse_front_matter("---\n" <> rest) do
    [head | _] = String.split(rest, "\n---", parts: 2)

    for line <- String.split(head, "\n"),
        [key, value] <- [String.split(line, ":", parts: 2)],
        into: %{} do
      value = String.trim(value)

      case Jason.decode(value) do
        {:ok, decoded} -> {String.trim(key), decoded}
        _ -> {String.trim(key), value}
      end
    end
  end

  def parse_front_matter(_), do: %{}
end
