defmodule Mix.Tasks.Catalog.Import do
  @shortdoc "Rebuild catalog apps/ from the signed objects"
  @moduledoc """
  Rebuild `apps/` from the signed indexes and bundles (keeping each application's
  categories from its current `MANIFEST.md`), then `CATALOG.md`.

      mix catalog.import [--root DIR]
  """
  use Mix.Task

  alias Manifests.CatalogTools.{Catalog, CLI, Docs, Json, Py}

  @usage "mix catalog.import [--root DIR]"

  @impl Mix.Task
  def run(args) do
    {_opts, positional, c} = CLI.parse!(args, [], @usage)

    if positional != [],
      do: CLI.usage_error!(@usage, "unrecognized arguments: #{Enum.join(positional, " ")}")

    CLI.run(fn ->
      {signed, order} = Catalog.signed_state(c)

      # Python iterates the state dict in insertion order: published, then drafts.
      ids = Enum.uniq(Map.get(order, "published", []) ++ Map.get(order, "drafts", []))

      for app_id <- ids do
        s = Map.fetch!(signed, app_id)
        entry = s.entry
        current = Path.join([Catalog.apps_dir(c), app_id, "MANIFEST.md"])

        kept =
          if File.exists?(current) do
            {meta, _} = current |> Catalog.read_text!() |> Catalog.parse_front_matter()
            Json.get(meta, "categories", [])
          else
            []
          end

        pairs = [
          {"title", Json.fetch!(entry, "title")},
          {"catalog", s.catalog},
          {"categories", kept}
        ]

        logo = Json.get(entry, "logo")
        pairs = if Py.truthy?(logo), do: pairs ++ [{"logo", logo}], else: pairs
        Catalog.write_app(c, app_id, Catalog.signed_payload(s), {:o, pairs}, signed)
      end

      Catalog.write!(Catalog.path(c, "CATALOG.md"), Docs.render_catalog(c, signed))
      IO.puts("imported #{map_size(signed)} applications into apps/")
    end)
  end
end
