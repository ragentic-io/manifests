defmodule Mix.Tasks.Catalog.Docs do
  @shortdoc "Regenerate catalog MANIFEST.md bodies and CATALOG.md"
  @moduledoc """
  Regenerate every `apps/<id>/MANIFEST.md` body (keeping its front matter) and
  `CATALOG.md`.

      mix catalog.docs [--root DIR]
  """
  use Mix.Task

  alias Manifests.CatalogTools.{Catalog, CLI, Docs}

  @usage "mix catalog.docs [--root DIR]"

  @impl Mix.Task
  def run(args) do
    {_opts, positional, c} = CLI.parse!(args, [], @usage)

    if positional != [],
      do: CLI.usage_error!(@usage, "unrecognized arguments: #{Enum.join(positional, " ")}")

    CLI.run(fn ->
      {signed, _} = Catalog.signed_state(c)
      Docs.regenerate(c, signed)
      IO.puts("wrote #{length(Catalog.app_ids(c))} MANIFEST.md files and CATALOG.md")
    end)
  end
end
