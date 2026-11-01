defmodule Manifests.CatalogTools.Validate do
  @moduledoc """
  `validate`: check every application's sources, the signed objects against the root
  pinned in `registry.json`, and that the generated docs are current. Prints the same
  report as `tools/catalog.py validate`.
  """

  alias Manifests.CatalogTools.{Catalog, Docs, Error, Graph, Json, Py, Trust}

  @id_re ~S"\A[a-z0-9][a-z0-9._-]{0,127}\z"
  @secret_re ~S"sk_live_[0-9A-Za-z]{16,}|gh[pousr]_[0-9A-Za-z]{30,}|xox[abpr]-[0-9A-Za-z-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  @secret_ok_re ~S"EXAMPLE|example|\.\.\.|…"

  @doc "Whether `id` is a valid application id."
  def valid_id?(id), do: is_binary(id) and Regex.match?(regex(:id), id)

  defp regex(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        source =
          case name do
            :id -> @id_re
            :secret -> @secret_re
            :secret_ok -> @secret_ok_re
          end

        r = Regex.compile!(source, "u")
        :persistent_term.put(key, r)
        r

      r ->
        r
    end
  end

  # --- Applications -----------------------------------------------------------

  @doc "Problems with one application's sources, in the Python tool's order."
  def check_app(c, app_id, payload, listing) do
    # `_need(errors, cond, msg)` appends to a list in Python; keep that shape with a
    # per-call accumulator in the process dictionary.
    key = {__MODULE__, make_ref()}
    Process.put(key, [])

    try do
      do_check_app(c, app_id, payload, listing, fn cond, msg ->
        unless cond, do: Process.put(key, [resolve_msg(msg) | Process.get(key)])
        cond
      end)

      key |> Process.get() |> Enum.reverse()
    after
      Process.delete(key)
    end
  end

  defp resolve_msg(f) when is_function(f, 0), do: f.()
  defp resolve_msg(msg), do: msg

  defp int?(v), do: is_integer(v) or is_boolean(v)

  defp do_check_app(c, app_id, payload, listing, need) do
    need.(valid_id?(app_id), "directory name must match [a-z0-9][a-z0-9._-]{0,127}")

    if need.(Json.dict?(payload), "manifest.json must be a JSON object") do
      check_payload(c, app_id, payload, listing, need)
    end
  end

  defp check_payload(c, app_id, payload, listing, need) do
    get = &Json.get(payload, &1)
    need.(Json.get(payload, "app", app_id) == app_id, "`app` must equal the directory name")
    need.(Json.get(payload, "kind", "bundle") == "bundle", "`kind` must be \"bundle\"")

    for k <- ~w(not_before expires),
        do: need.(int?(Json.get(payload, k, 0)), "`#{k}` must be an integer (set by signing)")

    protocol = get.("protocol")
    protocols = Catalog.protocols()
    need.(protocol in protocols, "`protocol` must be one of #{Enum.join(protocols, ", ")}")
    v = get.("version")
    need.(is_binary(v) and byte_size(v) in 1..128, "`version` must be 1-128 bytes")
    need.(is_binary(get.("readiness")), "`readiness` is required")
    need.(Json.dict?(get.("review_required")), "`review_required` is required")
    prov = get.("provenance")

    if need.(Json.dict?(prov), "`provenance` is required") do
      need.(is_binary(Json.get(prov, "url")), "`provenance.url` must name the source definition")

      need.(
        Regex.match?(~r/\A[0-9a-f]{64}\z/, Py.str(Json.get(prov, "sha256"))),
        "`provenance.sha256` must be hex"
      )
    end

    m = get.("manifest")

    document =
      if need.(Json.dict?(m), "`manifest` is required") do
        need.(
          Json.get(m, "apiVersion") == "ragentic.dev/v1",
          "`manifest.apiVersion` must be ragentic.dev/v1"
        )

        need.(
          Json.get(m, "kind") == "ConnectorTemplate",
          "`manifest.kind` must be ConnectorTemplate"
        )

        need.(
          m |> Json.get("metadata") |> Py.py_or(%{}) |> Json.get("name") == app_id,
          "`manifest.metadata.name` must equal the id"
        )

        spec = m |> Json.get("spec") |> Py.py_or(%{})
        need.(is_binary(Json.get(spec, "title")), "`manifest.spec.title` is required")
        base = spec |> Json.get("base") |> Py.py_or(%{})

        need.(
          Json.get(base, "protocol") == protocol,
          "`manifest.spec.base.protocol` must equal `protocol`"
        )

        specification = base |> Json.get("specification") |> Py.py_or(%{})
        document = Json.get(specification, "document")

        need.(
          Json.dict?(document) or
            (protocol == "graphql" and is_binary(Json.get(specification, "text"))),
          "`manifest.spec.base.specification` needs a `document` object (or SDL `text` for GraphQL)"
        )

        if Json.has?(base, "endpoint") do
          need.(
            String.starts_with?(Py.str(Json.get(base, "endpoint")), "https://"),
            "`manifest.spec.base.endpoint` must be https"
          )
        end

        secrets(Json.get(base, "headers", %{}), "manifest.spec.base.headers", need)
        document
      end

    graph = get.("graph")

    if need.(Json.dict?(graph), "`graph` is required") do
      nodes = Json.get(graph, "nodes")
      edges = Json.get(graph, "edges")

      if need.(is_list(nodes) and is_list(edges), "`graph` needs nodes and edges") do
        ids = for n <- nodes, Json.dict?(n), into: MapSet.new(), do: Json.plain(Json.get(n, "id"))

        need.(
          Enum.all?(nodes, &(Json.dict?(&1) and Json.has?(&1, "id") and Json.has?(&1, "kind"))),
          "graph nodes need id and kind"
        )

        need.(
          Enum.all?(edges, fn x ->
            MapSet.member?(ids, Json.plain(Json.get(x, "from"))) and
              MapSet.member?(ids, Json.plain(Json.get(x, "to")))
          end),
          "graph edges must join known nodes"
        )

        if protocol == "openapi" and Json.dict?(document) do
          need.(
            Graph.sorted_graph(graph) == Graph.sorted_graph(Graph.openapi_graph(app_id, document)),
            "`graph` is out of date; run `python tools/catalog.py graph #{app_id}`"
          )
        end
      end
    end

    check_listing(c, listing, need)
    check_catalog(payload, listing, m, need)

    for k <- ~w(setup a2ui), do: secrets(Json.get(payload, k, %{}), k, need)

    need.(
      byte_size(Json.canonical(payload)) <= Catalog.max_payload(),
      "payload is larger than 16 MiB"
    )
  end

  defp check_listing(c, listing, need) do
    title = Json.get(listing, "title")

    need.(
      is_binary(title) and byte_size(title) in 1..256,
      "front matter `title` must be 1-256 bytes"
    )

    need.(
      Json.get(listing, "catalog") in Catalog.catalog_names(),
      "front matter `catalog` must be \"published\" or \"drafts\""
    )

    if Json.has?(listing, "logo") do
      need.(
        String.starts_with?(Py.str(Json.get(listing, "logo")), "https://"),
        "front matter `logo` must be an https URL"
      )
    end

    cats = Json.get(listing, "categories")
    known = Catalog.categories(c)
    max = Catalog.max_categories()

    if need.(
         is_list(cats) and length(cats) in 1..max and
           length(Enum.uniq_by(cats, &Json.plain/1)) == length(cats),
         "front matter `categories` must list 1-#{max} distinct ids from categories.json"
       ) do
      unknown = Enum.reject(cats, &Json.has?(known, &1))

      need.(
        unknown == [],
        fn ->
          "front matter `categories` has unknown ids #{Py.repr(unknown)}; see categories.json"
        end
      )
    end

    need.(
      Enum.all?(Json.keys(listing), &(&1 in ~w(title catalog categories logo))),
      "front matter allows only title, catalog, categories and logo"
    )
  end

  defp check_catalog(payload, listing, m, need) do
    catalog = Json.get(listing, "catalog")

    if catalog == "drafts" do
      need.(
        is_binary(Json.get(payload, "setup_verification")),
        "drafts need `setup_verification`"
      )

      need.(
        Json.get(payload, "readiness") in Catalog.draft_readiness(),
        "drafts need `readiness` #{Enum.join(Catalog.draft_readiness(), " or ")}"
      )
    end

    if catalog in Catalog.catalog_names() and Json.dict?(m) do
      status = if catalog == "drafts", do: "draft", else: "published"

      need.(
        m |> Json.get("spec") |> Py.py_or(%{}) |> Json.get("status") == status,
        "#{catalog} need `manifest.spec.status` \"#{status}\""
      )
    end

    if catalog == "published" do
      need.(
        Json.get(payload, "readiness") not in Catalog.not_connectable(),
        "published apps cannot have readiness discovered/preview_only"
      )

      setup = payload |> Json.get("setup") |> Py.py_or(%{})
      need.(Json.dict?(Json.get(setup, "credential")), "published apps need `setup.credential`")

      need.(
        Json.dict?(Json.get(setup, "probe")),
        "published apps need a `setup.probe` connection test"
      )

      rights = payload |> Json.get("rights") |> Py.py_or(%{})

      need.(
        Json.dict?(Json.get(rights, "source")),
        "published apps need `rights.source` (license)"
      )

      need.(
        Json.dict?(Json.get(rights, "brand")),
        "published apps need `rights.brand` (attribution)"
      )

      need.(
        payload |> Json.get("a2ui") |> Py.py_or(%{}) |> Json.get("messages") |> Py.truthy?(),
        "published apps need an `a2ui` setup form"
      )
    end
  end

  defp secrets(obj, where, need) do
    cond do
      Json.dict?(obj) ->
        for {k, v} <- Json.items(obj), do: secrets(v, "#{where}.#{Py.str(k)}", need)

      is_list(obj) ->
        obj |> Enum.with_index() |> Enum.each(fn {v, i} -> secrets(v, "#{where}[#{i}]", need) end)

      is_binary(obj) ->
        need.(
          not (Regex.match?(regex(:secret), obj) and not Regex.match?(regex(:secret_ok), obj)),
          "#{where} looks like a real credential"
        )

      true ->
        :ok
    end
  end

  # --- Signed objects -------------------------------------------------------------

  @doc "Errors verifying both indexes, every bundle they name and stray bundles."
  def check_signed(c) do
    cfg = Catalog.config(c)
    root = Trust.b64d(Json.fetch!(cfg, "root"))

    Enum.flat_map(Catalog.catalogs(), fn {catalog, {name, directory, kind}} ->
      case Catalog.read_index(c, catalog) do
        {nil, _} ->
          ["#{name}: missing"]

        {env, _} ->
          with {:ok, data} <- Trust.open_envelope(env, root),
               {:ok, index} <- decode(data) do
            check_index(c, catalog, name, directory, kind, index, cfg, root)
          else
            {:error, _} ->
              ["#{name}: signature does not verify against the root in registry.json"]
          end
      end
    end)
  end

  defp decode(data) do
    {:ok, Json.decode_bytes!(data)}
  rescue
    Error -> {:error, :json}
  end

  defp check_index(c, catalog, name, directory, kind, index, cfg, root) do
    errors =
      if Json.get(index, "kind") != kind or
           Json.get(index, "registry") != Json.fetch!(cfg, "registry"),
         do: ["#{name}: wrong kind or registry"],
         else: []

    entries = Json.fetch!(index, "entries")
    ids = Enum.map(entries, &Json.plain(Json.fetch!(&1, "id")))

    errors =
      if length(ids) != length(Enum.uniq(ids)),
        do: errors ++ ["#{name}: duplicate ids"],
        else: errors

    {errors, named} =
      entries
      |> Catalog.pmap(fn entry ->
        path = Catalog.bundle_path(c, catalog, Json.fetch!(entry, "digest"))
        file = Path.basename(path)
        {file, check_bundle(path, "#{directory}/#{file}", entry, root)}
      end)
      |> Enum.reduce({errors, MapSet.new()}, fn {file, bundle_errors}, {errors, named} ->
        {errors ++ bundle_errors, MapSet.put(named, file)}
      end)

    stray =
      case File.ls(Catalog.path(c, directory)) do
        {:ok, names} ->
          names
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.reject(&MapSet.member?(named, &1))

        {:error, _} ->
          []
      end

    errors ++ Enum.map(Enum.sort(stray), &"#{directory}/#{&1}: not named by #{name}")
  end

  defp check_bundle(path, label, entry, root) do
    if File.exists?(path) do
      wrapper = Catalog.read_json!(path)

      case Trust.open_envelope(Json.fetch!(wrapper, "envelope"), root) do
        {:error, _} ->
          ["#{label}: bad signature"]

        {:ok, data} ->
          p = Json.decode_bytes!(data)

          digest_error =
            if Trust.sha256(data) != Json.fetch!(entry, "digest") or
                 Json.get(wrapper, "chain") != [],
               do: ["#{label}: digest or chain mismatch"],
               else: []

          app_error =
            if not Json.eq?(Json.get(p, "app"), Json.fetch!(entry, "id")) or
                 not Json.eq?(Json.get(p, "version"), Json.fetch!(entry, "version")),
               do: ["#{label}: app or version differs from the index"],
               else: []

          digest_error ++ app_error
      end
    else
      ["#{label}: missing for #{Py.str(Json.fetch!(entry, "id"))}"]
    end
  end

  @doc "Plain-text files that differ from the signed sources.json (nil when it is absent)."
  def check_sources(c) do
    path = Catalog.path(c, "sources.json")

    if File.exists?(path) do
      root = c |> Catalog.config() |> Json.fetch!("root") |> Trust.b64d()

      data =
        case Trust.open_envelope(Catalog.read_json!(path), root) do
          {:ok, data} -> data
          {:error, reason} -> raise Error, "sources.json: #{reason}"
        end

      signed = data |> Json.decode_bytes!() |> Json.fetch!("files") |> Json.plain()
      now = Catalog.source_files(c)

      MapSet.new(Map.keys(signed) ++ Map.keys(now))
      |> Enum.filter(&(Map.get(signed, &1) != Map.get(now, &1)))
      |> Enum.sort()
    end
  end

  # --- Command --------------------------------------------------------------------

  @doc """
  Run `validate`, printing the report. Returns `:ok` or `{:error, 1}` when anything
  failed (the task exits with that status).
  """
  def run(c, opts \\ []) do
    require_signed = Keyword.get(opts, :require_signed, false)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    cfg = Catalog.config(c)
    refresh = Json.fetch!(cfg, "refresh_days") * 86_400
    errors = check_signed(c)
    {signed, _} = Catalog.signed_state(c)
    ids = Catalog.app_ids(c)

    {errors, waiting, stale_docs} =
      ids
      |> Catalog.pmap(&check_one(c, &1, signed, now, refresh))
      |> Enum.reduce({errors, %{}, []}, fn {app_id, app_errors, reasons, stale?},
                                           {errors, waiting, stale} ->
        waiting = if reasons in [nil, []], do: waiting, else: Map.put(waiting, app_id, reasons)
        {errors ++ app_errors, waiting, if(stale?, do: [app_id | stale], else: stale)}
      end)

    waiting =
      signed
      |> Map.keys()
      |> Enum.reject(&(&1 in ids))
      |> Enum.reduce(waiting, &Map.put(&2, &1, ["removed from apps/; will be unpublished"]))

    stale_docs = Enum.reverse(stale_docs)
    catalog_md = Catalog.path(c, "CATALOG.md")

    stale_docs =
      if not File.exists?(catalog_md) or
           Catalog.read_text!(catalog_md) != Docs.render_catalog(c, signed),
         do: stale_docs ++ ["CATALOG.md"],
         else: stale_docs

    errors =
      if stale_docs != [] do
        more = if length(stale_docs) > 10, do: " …", else: ""

        errors ++
          [
            "generated docs are out of date for #{stale_docs |> Enum.take(10) |> Enum.join(", ")}" <>
              "#{more}; run `python tools/catalog.py docs`"
          ]
      else
        errors
      end

    changed = check_sources(c)
    n_waiting = map_size(waiting)

    IO.puts(
      "#{length(ids)} applications, #{length(ids) - n_waiting} signed and current, #{n_waiting} waiting for signature"
    )

    waiting
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(50)
    |> Enum.each(fn {app_id, reasons} ->
      IO.puts("  pending  #{app_id}: #{Enum.join(reasons, "; ")}")
    end)

    if n_waiting > 50, do: IO.puts("  … and #{n_waiting - 50} more")

    cond do
      changed == nil ->
        IO.puts("sources.json: not signed yet")

      changed != [] ->
        IO.puts("sources.json: #{length(changed)} plain-text files changed since signing")

      true ->
        :ok
    end

    errors =
      if require_signed do
        errors
        |> then(
          &if n_waiting > 0, do: &1 ++ ["#{n_waiting} applications are not signed"], else: &1
        )
        |> then(
          &if changed == nil or changed != [],
            do: &1 ++ ["sources.json does not cover the current plain-text files"],
            else: &1
        )
      else
        errors
      end

    Enum.each(errors, &IO.puts("ERROR #{&1}"))

    if errors == [] do
      IO.puts("ok")
      :ok
    else
      {:error, 1}
    end
  end

  # One application's {id, errors, pending reasons, stale docs?}.
  defp check_one(c, app_id, signed, now, refresh) do
    folder = Path.join(Catalog.apps_dir(c), app_id)

    extra =
      folder
      |> File.ls!()
      |> Enum.reject(&(&1 in ["manifest.json", "MANIFEST.md"]))
      |> Enum.sort()

    errors = if extra != [], do: ["apps/#{app_id}: unexpected files #{Py.repr(extra)}"], else: []

    case load(c, app_id) do
      {:error, msg} ->
        {app_id, errors ++ ["apps/#{app_id}: #{msg}"], nil, false}

      {:ok, {payload, listing, body}} ->
        case check_app(c, app_id, payload, listing) do
          [] ->
            stale? = body != Docs.render(c, app_id, payload, listing, signed)

            {app_id, errors, Catalog.pending(app_id, payload, listing, signed, now, refresh),
             stale?}

          problems ->
            {app_id, errors ++ Enum.map(problems, &"apps/#{app_id}: #{&1}"), nil, false}
        end
    end
  end

  defp load(c, app_id) do
    {:ok, Catalog.load_app(c, app_id)}
  rescue
    e in Error -> {:error, e.message}
  end
end
