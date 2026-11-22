defmodule Mix.Tasks.Catalog.Import do
  @shortdoc "Rebuild catalog apps/ from the signed objects"
  @moduledoc """
  Rebuild `apps/` from the signed indexes and bundles (keeping each application's
  categories from its current `MANIFEST.md`), then `CATALOG.md`.

      mix catalog.import [--root DIR]

  With a source, import items of any kind instead (docs/registry.md in ragentic, 3):

      mix catalog.import agency-agents [--from DIR] [--commit SHA]
      mix catalog.import ragentic-examples --from DIR [--commit SHA]

  `agency-agents` reads a checkout of msitarzewski/agency-agents (`--from`) or
  downloads the commit pinned in `catalog/sources/agency-agents/tiers.json`;
  `ragentic-examples` reads a ragentic checkout, at `--commit` when given.
  Both write `catalog/items/<id>/`, bumping versions by what changed.
  """
  use Mix.Task

  alias Manifests.CatalogTools.{Catalog, CLI, Docs, Json, Py}

  @usage "mix catalog.import [agency-agents | ragentic-examples] [--from DIR] [--commit SHA] [--root DIR]"

  @impl Mix.Task
  def run(args) do
    {opts, positional, c} = CLI.parse!(args, [from: :string, commit: :string], @usage)

    case positional do
      [] -> import_apps(c)
      ["agency-agents"] -> import_items(c, Manifests.Items.AgencyAgents, opts)
      ["ragentic-examples"] -> import_items(c, Manifests.Items.RagenticExamples, opts)
      other -> CLI.usage_error!(@usage, "unrecognized arguments: #{Enum.join(other, " ")}")
    end
  end

  defp import_items(c, importer, opts) do
    if importer == Manifests.Items.RagenticExamples and is_nil(opts[:from]),
      do: CLI.usage_error!(@usage, "ragentic-examples needs --from DIR (a ragentic checkout)")

    Application.ensure_all_started(:req)

    CLI.run(fn ->
      r = importer.run(c, Keyword.take(opts, [:from, :commit]))

      IO.puts(
        "#{r.written} items written, #{r.unchanged} unchanged, #{length(r.removed)} removed (commit #{r.commit})"
      )

      Enum.each(r.removed, &IO.puts("  removed #{&1}"))
      Enum.each(Map.get(r, :skipped, []), &IO.puts("  skipped #{&1}: not in the checkout"))
      :ok
    end)
  end

  defp import_apps(c) do
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
