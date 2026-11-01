defmodule Manifests.Catalog do
  @moduledoc "Pinned trust settings and entry points for loading signed catalogs."
  alias Manifests.Catalog.Import

  def config, do: Application.fetch_env!(:manifests, :registry)

  def root, do: config()[:root_public_key] |> Base.decode16!(case: :mixed)
  def registry_id, do: config()[:id]
  def root_key_id, do: Manifests.Trust.key_id(root())

  @doc "Import the signed catalog in `dir` (default: the configured, baked-in one)."
  def import_dir(dir \\ config()[:catalog_dir], opts \\ []) do
    Import.run(
      Import.dir(dir),
      Keyword.merge(
        [
          root: root(),
          registry: registry_id(),
          min_sequence: config()[:min_sequence],
          commit: config()[:catalog_commit]
        ],
        opts
      )
    )
  end

  @doc """
  Replay the catalog's git history oldest first, so every version ever signed is
  kept. Each commit is checked against the root its own `registry.json` pinned,
  as of when it was signed. `prefix` is the catalog's path inside the repo.
  """
  def backfill(repo, prefix \\ "catalog", log \\ &IO.puts/1) do
    prefix = String.trim_trailing(prefix, "/")

    # Commits from before the catalog moved under `prefix` have it at the root.
    {out, 0} =
      System.cmd("git", [
        "-C",
        repo,
        "log",
        "--reverse",
        "--topo-order",
        "--format=%H",
        "--",
        "#{prefix}/index.json",
        "#{prefix}/browse-index.json",
        "index.json",
        "browse-index.json"
      ])

    commits = String.split(out, "\n", trim: true)

    for {commit, n} <- Enum.with_index(commits, 1) do
      git = Import.git(repo, commit)
      at = if git.("#{prefix}/registry.json") != :error, do: "#{prefix}/", else: ""
      source = fn rel -> git.(at <> rel) end

      roots =
        with {:ok, body} <- source.("registry.json"),
             {:ok, %{"root" => encoded}} <- Jason.decode(body) do
          [encoded]
        else
          _ -> config()[:retired_roots] || []
        end

      results =
        for encoded <- roots, {:ok, root} <- [Base.url_decode64(encoded, padding: false)] do
          {:ok, result} =
            Import.run(source,
              root: root,
              registry: registry_id(),
              commit: commit,
              historical: true
            )

          result
        end

      log.("[#{n}/#{length(commits)}] #{String.slice(commit, 0, 7)} #{inspect(results)}")
    end

    :ok
  end
end

defmodule Manifests.Catalog.Loader do
  @moduledoc "Imports the baked-in signed catalog once the repo is up, without blocking boot."
  use Task, restart: :transient
  require Logger

  def start_link(_), do: Task.start_link(&run/0)

  def run do
    if Manifests.Catalog.config()[:import_on_boot] do
      dir = Manifests.Catalog.config()[:catalog_dir]

      if File.exists?(Path.join(dir, "index.json")) do
        {micros, {:ok, result}} = :timer.tc(fn -> Manifests.Catalog.import_dir(dir) end)
        Logger.info("catalog imported from #{dir} in #{div(micros, 1000)}ms: #{inspect(result)}")
      else
        Logger.warning("no signed catalog at #{dir}; serving what the database already has")
      end
    end
  end
end
