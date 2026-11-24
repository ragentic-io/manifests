defmodule Manifests.Items.Sign do
  @moduledoc """
  Sign pending items with the registry root key: each item whose sources differ
  from its signed bundle (or whose signature expires within `refresh_days`) is
  sealed into `item-bundles/<digest>.json` with fresh `not_before`/`expires`;
  `items-index.json` is re-signed with the next sequence when its entries
  changed or it nears expiry, and bundles it no longer names are deleted.

  Same envelope, canonical JSON and key as the apps (`Manifests.CatalogTools.Sign`),
  called from `mix catalog.sign` in the same run.
  """

  alias Manifests.CatalogTools.{Catalog, Error, Json, Trust}
  alias Manifests.Items
  alias Manifests.Items.Validate

  @doc "Options: `:key` (seed, nil when dry-running), `:now`, `:dry_run`. Returns the plan."
  def run(c, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)
    key = Keyword.get(opts, :key)
    now = Keyword.fetch!(opts, :now)
    cfg = Catalog.config(c)
    validity = Json.fetch!(cfg, "validity_days") * 86_400
    refresh = Json.fetch!(cfg, "refresh_days") * 86_400
    report = Validate.run(c, now: now)

    case Enum.reject(report.errors, &String.starts_with?(&1, "items-index.json")) do
      [] -> :ok
      [first | _] -> raise Error, "#{first} (run validate)"
    end

    index = Items.read_index(c)
    signed = Map.new((index && index["entries"]) || [], &{&1["id"], &1})

    {entries, plan} =
      Enum.map_reduce(Items.ids(c), %{}, fn id, plan ->
        payload = Items.load(c, id)
        reasons = Map.get(report.waiting, id, [])
        entry = signed[id]

        if reasons == [] and entry do
          {entry, plan}
        else
          sealed =
            payload
            |> Map.put("not_before", now)
            |> Map.put("expires", now + validity)

          digest =
            if dry_run do
              String.duplicate("0", 64)
            else
              {data, env} = Trust.seal(sealed, key)
              digest = Trust.sha256(data)
              path = Items.bundle_path(c, digest)
              File.mkdir_p!(Path.dirname(path))
              Catalog.write!(path, Json.compact(%{"chain" => [], "envelope" => env}))
              digest
            end

          {Items.index_entry(sealed, digest), Map.put(plan, id, reasons)}
        end
      end)

    changed? =
      index == nil or Json.plain(index["entries"]) != Json.plain(entries) or
        index["expires"] - now < refresh

    IO.puts(
      "#{map_size(plan)} items to sign, items index: " <>
        if(changed?, do: "re-signed", else: "unchanged")
    )

    plan
    |> Enum.sort()
    |> Enum.take(50)
    |> Enum.each(fn {id, r} -> IO.puts("  #{id}: #{Enum.join(r, "; ")}") end)

    if changed? and not dry_run do
      payload = %{
        "entries" => entries,
        "expires" => now + validity,
        "kind" => "items_index",
        "not_before" => now,
        "registry" => Json.fetch!(cfg, "registry"),
        "sequence" => ((index && index["sequence"]) || 0) + 1
      }

      {_, env} = Trust.seal(payload, key)
      Catalog.write!(Catalog.path(c, Items.index_file()), Json.compact(env))
      prune(c, entries)
    end

    plan
  end

  defp prune(c, entries) do
    live = MapSet.new(entries, &"#{&1["digest"]}.json")
    dir = Catalog.path(c, Items.bundles_dir())

    case File.ls(dir) do
      {:ok, files} ->
        for f <- files,
            String.ends_with?(f, ".json"),
            not MapSet.member?(live, f),
            do: File.rm!(Path.join(dir, f))

      _ ->
        :ok
    end
  end
end
