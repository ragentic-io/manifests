defmodule Mix.Tasks.Catalog.New do
  @shortdoc "Scaffold a draft catalog application from an OpenAPI document"
  @moduledoc """
  Scaffold a draft application from a provider's OpenAPI 3 or Swagger 2 definition
  (JSON or YAML).

      mix catalog.new ID --openapi URL --category ID [--category ID ...]
        [--title TITLE] [--endpoint URL]
        [--credential none|static_bearer|api_key_header] [--header NAME] [--prefix PREFIX]
        [--root DIR]

  The definition is fetched and embedded, its URL and SHA-256 are recorded under
  `provenance`, the operation graph is generated and `apps/ID/manifest.json`,
  `MANIFEST.md` and `CATALOG.md` are written.

    * `--openapi` - URL of the OpenAPI or Swagger document (`https://` or `file://`)
    * `--category` - a category id from categories.json; repeat for up to four
    * `--title` - the listing title (defaults to the definition's `info.title`)
    * `--endpoint` - https base URL; defaults to the first https server in the document
    * `--credential` - `none`, `static_bearer` or `api_key_header`
    * `--header` - header name for `api_key_header`
    * `--prefix` - value prefix for `api_key_header`, e.g. `Bearer`
    * `--root` - the catalog directory (default: `catalog/` in this project)
  """
  use Mix.Task

  alias Manifests.CatalogTools.{CLI, Scaffold}

  @usage "mix catalog.new ID --openapi URL --category ID [--category ID ...] [--title TITLE] " <>
           "[--endpoint URL] [--credential {none,static_bearer,api_key_header}] [--header HEADER] " <>
           "[--prefix PREFIX] [--root DIR]"

  @impl Mix.Task
  def run(args) do
    {opts, positional, catalog} =
      CLI.parse!(
        args,
        [
          openapi: :string,
          title: :string,
          endpoint: :string,
          credential: :string,
          header: :string,
          prefix: :string,
          category: :keep
        ],
        @usage
      )

    missing =
      [openapi: "--openapi", category: "--category"]
      |> Enum.reject(fn {k, _} -> Keyword.has_key?(opts, k) end)
      |> Enum.map(&elem(&1, 1))

    id =
      case positional do
        [id] ->
          id

        [] ->
          CLI.usage_error!(
            @usage,
            "the following arguments are required: #{Enum.join(["id" | missing], ", ")}"
          )

        [_ | extra] ->
          CLI.usage_error!(@usage, "unrecognized arguments: #{Enum.join(extra, " ")}")
      end

    if missing != [],
      do:
        CLI.usage_error!(
          @usage,
          "the following arguments are required: #{Enum.join(missing, ", ")}"
        )

    credential = Keyword.get(opts, :credential)

    if credential && credential not in Scaffold.credentials() do
      CLI.usage_error!(
        @usage,
        "argument --credential: invalid choice: '#{credential}' (choose from 'none', 'static_bearer', 'api_key_header')"
      )
    end

    CLI.run(fn ->
      Scaffold.run(catalog, id,
        openapi: opts[:openapi],
        categories: Keyword.get_values(opts, :category),
        title: opts[:title],
        endpoint: opts[:endpoint],
        credential: credential,
        header: opts[:header],
        prefix: opts[:prefix],
        now: opts[:now]
      )
    end)
  end
end
