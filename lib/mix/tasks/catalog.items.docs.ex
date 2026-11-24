defmodule Mix.Tasks.Catalog.Items.Docs do
  @shortdoc "Regenerate every item's ITEM.md listing"
  @moduledoc """
  Regenerate `catalog/items/<id>/ITEM.md` from each item's `item.json` and
  `manifests.yaml` (`Manifests.Items.render_listing/1`).

      mix catalog.items.docs [--root DIR]
  """
  use Mix.Task

  alias Manifests.CatalogTools.CLI
  alias Manifests.Items

  @impl Mix.Task
  def run(args) do
    {_opts, _positional, c} = CLI.parse!(args, [], "mix catalog.items.docs [--root DIR]")

    for id <- Items.ids(c) do
      File.write!(
        Path.join(Items.item_dir(c, id), "ITEM.md"),
        Items.render_listing(Items.load(c, id))
      )
    end

    IO.puts("#{length(Items.ids(c))} listings written")
  end
end
