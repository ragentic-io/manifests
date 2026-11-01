defmodule Manifests.Release do
  @moduledoc """
  Tasks run from the release, e.g. `bin/manifests eval Manifests.Release.migrate`.
  """
  @app :manifests

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc "Import a signed catalog directory by hand (the boot loader does this for the baked one)."
  def import_catalog(dir) do
    {:ok, _} = Application.ensure_all_started(@app)
    Manifests.Catalog.import_dir(dir) |> IO.inspect(label: "import")
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
