defmodule Manifests.CatalogTools.CLI do
  @moduledoc """
  Shared option handling for the `mix catalog.*` tasks: `--root` (default
  `catalog/` in the project), the hidden `--now UNIX_SECONDS` used to make signing
  and scaffolding reproducible in tests, and Python-style error reporting
  (`error: ...` with status 1, usage errors with status 2).
  """

  alias Manifests.CatalogTools.{Catalog, Error}

  @common [root: :string, now: :integer]

  @doc """
  Parse `args` with `switches` (plus `--root`/`--now`). Returns
  `{opts, positional, catalog}`; unknown or malformed options are usage errors.
  """
  def parse!(args, switches, usage) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: switches ++ @common)

    case invalid do
      [] ->
        :ok

      [{flag, nil} | _] ->
        usage_error!(usage, "unrecognized arguments: #{flag}")

      [{flag, value} | _] ->
        usage_error!(usage, "argument #{flag}: invalid value: #{inspect(value)}")
    end

    if Enum.any?(positional, &String.starts_with?(&1, "-")) do
      usage_error!(
        usage,
        "unrecognized arguments: #{Enum.join(Enum.filter(positional, &String.starts_with?(&1, "-")), " ")}"
      )
    end

    {opts, positional, Catalog.new(Keyword.get(opts, :root) || default_root())}
  end

  @doc "The catalog directory of the current Mix project (`catalog/`)."
  def default_root do
    dir =
      case Mix.Project.project_file() do
        nil -> File.cwd!()
        file -> Path.dirname(file)
      end

    Path.join(dir, "catalog")
  end

  @doc "Print `usage` and `error: msg` to stderr and exit with status 2 (argparse style)."
  def usage_error!(usage, msg) do
    IO.puts(:stderr, "usage: #{usage}")
    IO.puts(:stderr, "error: #{msg}")
    exit({:shutdown, 2})
  end

  @doc "Run `fun`, turning a `Manifests.CatalogTools.Error` into `error: ...` and status 1."
  def run(fun) do
    case fun.() do
      {:error, status} -> exit({:shutdown, status})
      _ -> :ok
    end
  rescue
    e in Error ->
      IO.puts(:stderr, "error: #{e.message}")
      exit({:shutdown, 1})
  end
end
