defmodule Mix.Tasks.Catalog.Sign do
  @shortdoc "Sign pending catalog changes with MANIFESTS_SIGNING_KEY"
  @moduledoc """
  Sign every pending change with the registry's Ed25519 root key: bundles into
  `bundles/` and `browse-bundles/`, the indexes `index.json` and `browse-index.json`,
  regenerated docs and `sources.json`; then items (`catalog/items/`) into
  `item-bundles/` and `items-index.json` (`Manifests.Items.Sign`).

      MANIFESTS_SIGNING_KEY=... mix catalog.sign [--dry-run] [--root DIR]

  The key is a 32-byte Ed25519 seed in hex or base64url, read only from the
  `MANIFESTS_SIGNING_KEY` environment variable; a key that doesn't match the root
  pinned in `registry.json` is refused.

    * `--dry-run` - show what would be signed without a key
  """
  use Mix.Task

  alias Manifests.CatalogTools.{Catalog, CLI, Json, Sign, Trust}

  @usage "mix catalog.sign [--dry-run] [--root DIR]"

  @impl Mix.Task
  def run(args) do
    {opts, positional, c} = CLI.parse!(args, [dry_run: :boolean], @usage)

    if positional != [],
      do: CLI.usage_error!(@usage, "unrecognized arguments: #{Enum.join(positional, " ")}")

    dry_run = Keyword.get(opts, :dry_run, false)
    now = opts[:now] || System.system_time(:second)

    CLI.run(fn ->
      Sign.run(c, dry_run: dry_run, now: now)

      # items of any kind: item-bundles/ and items-index.json, same key
      key = if dry_run, do: nil, else: Trust.signing_key!(Json.fetch!(Catalog.config(c), "root"))
      Manifests.Items.Sign.run(c, key: key, now: now, dry_run: dry_run)
      :ok
    end)
  end
end
