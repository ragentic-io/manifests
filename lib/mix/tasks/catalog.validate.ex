defmodule Mix.Tasks.Catalog.Validate do
  @shortdoc "Check catalog sources, signatures and generated docs"
  @moduledoc """
  Check every application's and item's sources, verify the signed indexes, bundles and
  `sources.json` against the root pinned in `registry.json`, and check that the
  generated docs are current. Ends with `ok`, or exits with status 1.

      mix catalog.validate [--require-signed] [--root DIR]

    * `--require-signed` - also fail when anything is waiting for signature
  """
  use Mix.Task

  alias Manifests.CatalogTools.{CLI, Validate}

  @usage "mix catalog.validate [--require-signed] [--root DIR]"

  @impl Mix.Task
  def run(args) do
    {opts, positional, c} = CLI.parse!(args, [require_signed: :boolean], @usage)

    if positional != [],
      do: CLI.usage_error!(@usage, "unrecognized arguments: #{Enum.join(positional, " ")}")

    require_signed = Keyword.get(opts, :require_signed, false)
    now = opts[:now] || now()

    CLI.run(fn ->
      apps = Validate.run(c, require_signed: require_signed, now: now)
      items = Manifests.Items.Validate.report(c, require_signed: require_signed, now: now)
      if apps == :ok and items == :ok, do: :ok, else: {:error, 1}
    end)
  end

  defp now, do: System.system_time(:second)
end
