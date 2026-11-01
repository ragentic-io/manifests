defmodule Manifests.CatalogTools.Sign do
  @moduledoc """
  `sign`: sign every pending change with the registry root key, exactly like
  `tools/catalog.py sign`.

  For each application whose sources differ from its signed bundle, or whose
  signature expires within `refresh_days`, it sets `not_before`/`expires`, signs the
  canonical payload into `bundles/` or `browse-bundles/` and writes the times back
  into `manifest.json`. It then rebuilds each index whose entries changed or that is
  close to expiry (keeping order, incrementing the sequence, deleting bundles it no
  longer names), regenerates the docs and re-signs `sources.json`.

  The key comes from `MANIFESTS_SIGNING_KEY` (see `Manifests.CatalogTools.Trust`).
  """

  alias Manifests.CatalogTools.{Catalog, Docs, Error, Json, Trust, Validate}

  @doc "Run `sign`. Options: `:dry_run`, `:now` (unix seconds)."
  def run(c, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    cfg = Catalog.config(c)
    validity = Json.fetch!(cfg, "validity_days") * 86_400
    refresh = Json.fetch!(cfg, "refresh_days") * 86_400
    key = if dry_run, do: nil, else: Trust.signing_key!(Json.fetch!(cfg, "root"))
    # After a root rotation, bundles signed by the old root are re-signed.
    root = Trust.b64d(Json.fetch!(cfg, "root"))
    {signed, order} = Catalog.signed_state(c)
    ids = Catalog.app_ids(c)

    {plan, entries} =
      ids
      |> Catalog.pmap(fn app_id ->
        {payload, listing, _} = Catalog.load_app(c, app_id)

        case Validate.check_app(c, app_id, payload, listing) do
          [] -> :ok
          [first | _] -> raise Error, "apps/#{app_id}: #{first} (run validate)"
        end

        catalog = Json.fetch!(listing, "catalog")
        s = Map.get(signed, app_id)
        reasons = Catalog.pending(app_id, payload, listing, signed, now, refresh)

        {payload, digest} =
          if s != nil and Catalog.same_payload?(s, payload) and s.expires - now >= refresh and
               verifies?(c, s.catalog, Json.fetch!(s.entry, "digest"), root) do
            # Same bytes; at most a listing change or a move.
            digest = Json.fetch!(s.entry, "digest")

            if s.catalog != catalog and not dry_run do
              dst = Catalog.bundle_path(c, catalog, digest)
              File.mkdir_p!(Path.dirname(dst))
              File.write!(dst, Catalog.read_bytes!(Catalog.bundle_path(c, s.catalog, digest)))
            end

            {payload, digest}
          else
            payload =
              payload
              |> Json.put("kind", "bundle")
              |> Json.put("app", app_id)
              |> Json.put("not_before", now)
              |> Json.put("expires", now + validity)

            if dry_run do
              {payload, String.duplicate("0", 64)}
            else
              {data, env} = Trust.seal(payload, key)
              digest = Trust.sha256(data)
              path = Catalog.bundle_path(c, catalog, digest)
              File.mkdir_p!(Path.dirname(path))
              Catalog.write!(path, Json.compact(%{"chain" => [], "envelope" => env}))

              Catalog.write!(
                Path.join([Catalog.apps_dir(c), app_id, "manifest.json"]),
                Json.pretty(payload)
              )

              {payload, digest}
            end
          end

        {app_id, catalog, reasons, Catalog.index_entry(app_id, payload, listing, digest)}
      end)
      |> Enum.reduce({%{}, %{"published" => %{}, "drafts" => %{}}}, fn {app_id, catalog, reasons,
                                                                        entry},
                                                                       {plan, entries} ->
        plan = if reasons != [], do: Map.put(plan, app_id, reasons), else: plan
        {plan, Map.update!(entries, catalog, &Map.put(&1, app_id, entry))}
      end)

    removed = signed |> Map.keys() |> Enum.reject(&(&1 in ids)) |> Enum.sort()

    changed_catalogs =
      for {catalog, {name, directory, kind}} <- Catalog.catalogs(),
          rebuild_index(
            c,
            catalog,
            name,
            directory,
            kind,
            entries,
            order,
            cfg,
            key,
            now,
            validity,
            refresh,
            dry_run
          ),
          do: name

    IO.puts(
      "#{map_size(plan)} applications to sign, #{length(removed)} to unpublish, indexes: " <>
        if(changed_catalogs == [], do: "unchanged", else: Enum.join(changed_catalogs, ", "))
    )

    plan
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(50)
    |> Enum.each(fn {app_id, reasons} -> IO.puts("  #{app_id}: #{Enum.join(reasons, "; ")}") end)

    Enum.each(removed, &IO.puts("  #{&1}: removed"))

    unless dry_run, do: sign_sources(c, cfg, key, now, validity, refresh)
    :ok
  end

  # Returns whether the index changed (and, unless dry-running, re-signs it).
  defp rebuild_index(
         c,
         catalog,
         name,
         directory,
         kind,
         entries,
         order,
         cfg,
         key,
         now,
         validity,
         refresh,
         dry_run
       ) do
    {_, index} = Catalog.read_index(c, catalog)
    catalog_entries = Map.fetch!(entries, catalog)
    keep = Enum.filter(Map.fetch!(order, catalog), &Map.has_key?(catalog_entries, &1))
    new = keep ++ (catalog_entries |> Map.keys() |> Enum.reject(&(&1 in keep)) |> Enum.sort())
    listed = Enum.map(new, &Map.fetch!(catalog_entries, &1))
    indexed? = index != nil and index != {:o, []}
    expiring = not indexed? or Json.fetch!(index, "expires") - now < refresh

    cond do
      indexed? and Json.eq?(Json.fetch!(index, "entries"), listed) and not expiring ->
        false

      dry_run ->
        true

      true ->
        sequence = Json.get(index || %{}, "sequence", 0) + 1

        payload = %{
          "entries" => listed,
          "expires" => now + validity,
          "kind" => kind,
          "not_before" => now,
          "registry" => Json.fetch!(cfg, "registry"),
          "sequence" => sequence
        }

        {_, env} = Trust.seal(payload, key)
        Catalog.write!(Catalog.path(c, name), Json.compact(env))
        live = MapSet.new(listed, &"#{&1["digest"]}.json")
        dir = Catalog.path(c, directory)

        case File.ls(dir) do
          {:ok, files} ->
            for f <- files,
                String.ends_with?(f, ".json"),
                not MapSet.member?(live, f),
                do: File.rm!(Path.join(dir, f))

          {:error, _} ->
            :ok
        end

        true
    end
  end

  defp sign_sources(c, cfg, key, now, validity, refresh) do
    {signed, _} = Catalog.signed_state(c)
    Docs.regenerate(c, signed)
    files = Catalog.source_files(c)
    previous = Catalog.path(c, "sources.json")

    old =
      if File.exists?(previous),
        do:
          previous
          |> Catalog.read_json!()
          |> Json.fetch!("payload")
          |> Trust.b64d()
          |> Json.decode_bytes!(),
        else: %{}

    if not Json.eq?(Json.get(old, "files"), files) or Json.get(old, "expires", 0) - now < refresh do
      {_, index} = Catalog.read_index(c, "published")

      {_, env} =
        Trust.seal(
          %{
            "expires" => now + validity,
            "files" => files,
            "kind" => "sources",
            "not_before" => now,
            "registry" => Json.fetch!(cfg, "registry"),
            "sequence" => Json.fetch!(index, "sequence")
          },
          key
        )

      Catalog.write!(previous, Json.compact(env))
      IO.puts("sources.json: signed #{map_size(files)} plain-text files")
    end
  end

  defp verifies?(c, catalog, digest, root) do
    with {:ok, bytes} <- File.read(Catalog.bundle_path(c, catalog, digest)),
         wrapper <- Json.decode_bytes!(bytes),
         true <- Json.dict?(wrapper) and Json.has?(wrapper, "envelope"),
         {:ok, _} <- Trust.open_envelope(Json.get(wrapper, "envelope"), root) do
      true
    else
      _ -> false
    end
  rescue
    Error -> false
    KeyError -> false
  end
end
