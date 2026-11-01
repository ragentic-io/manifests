defmodule Mix.Tasks.Catalog.Sign do
  @shortdoc "Sign pending catalog changes with MANIFESTS_SIGNING_KEY"
  @moduledoc """
  Sign every pending change with the registry's Ed25519 root key: bundles into
  `bundles/` and `browse-bundles/`, the indexes `index.json` and `browse-index.json`,
  regenerated docs and `sources.json`.

      MANIFESTS_SIGNING_KEY=... mix catalog.sign [--dry-run] [--root DIR]

  The key is a 32-byte Ed25519 seed in hex or base64url, read only from the
  `MANIFESTS_SIGNING_KEY` environment variable; a key that doesn't match the root
  pinned in `registry.json` is refused.

    * `--dry-run` - show what would be signed without a key
  """
  use Mix.Task

  alias Manifests.CatalogTools.{CLI, Sign}

  @usage "mix catalog.sign [--dry-run] [--root DIR]"

  @impl Mix.Task
  def run(args) do
    {opts, positional, c} = CLI.parse!(args, [dry_run: :boolean], @usage)

    if positional != [],
      do: CLI.usage_error!(@usage, "unrecognized arguments: #{Enum.join(positional, " ")}")

    CLI.run(fn ->
      Sign.run(c,
        dry_run: Keyword.get(opts, :dry_run, false),
        now: opts[:now] || System.system_time(:second)
      )
    end)
  end
end
