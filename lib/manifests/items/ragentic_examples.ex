defmodule Manifests.Items.RagenticExamples do
  @moduledoc """
  ragentic's own examples (`examples/*.yaml` in ragentic-io/ragentic) as items,
  read at a pinned ragentic commit (docs/registry.md, 3.2). The examples stay
  authored in ragentic, where their tests and docs live; this importer makes
  the items, configured by the reviewed `catalog/sources/ragentic-examples/items.json`.

  On import:

    * an Agent's `spec.model` and `spec.fallback` are dropped (the example's
      provider is DJ's, not the reader's): `models` carries the suggested tier;
    * a Team's `spec.spawn.model` is dropped for the same reason;
    * kinds listed in an entry's `strip` are removed (credentials, model
      providers, chat bots wired to one machine); a file that still holds a
      kind no item may ship is refused;
    * `replace` substitutes literal placeholders (`__NAMESPACE__`) the example
      leaves for its installer.
  """

  alias Manifests.CatalogTools.Catalog
  alias Manifests.Items
  alias Manifests.Items.{Importer, Validate}

  def config_path(c), do: Catalog.path(c, "sources/ragentic-examples/items.json")
  def config(c), do: Importer.read_json!(config_path(c))

  @doc "Import from a ragentic checkout (`:from`, required), at `:commit` when given."
  def run(c, opts) do
    from = Keyword.fetch!(opts, :from)
    cfg = config(c)
    commit = opts[:commit] || Importer.git_commit(from) || cfg["commit"]
    read = reader(from, opts[:commit])
    examples = Importer.model_examples(c)

    {payloads, skipped} =
      Enum.reduce(cfg["items"], {[], []}, fn entry, {ok, skipped} ->
        case read.(entry["path"]) do
          {:ok, bytes} -> {[payload(entry, bytes, cfg, examples, commit) | ok], skipped}
          :error -> {ok, [entry["path"] | skipped]}
        end
      end)

    ids = MapSet.new(cfg["items"], & &1["id"])

    c
    |> Importer.write_all(Enum.reverse(payloads), &MapSet.member?(ids, &1))
    |> Map.merge(%{commit: commit, skipped: Enum.reverse(skipped)})
  end

  defp reader(from, nil) do
    fn path ->
      case File.read(Path.join(from, path)) do
        {:ok, bytes} -> {:ok, bytes}
        _ -> :error
      end
    end
  end

  defp reader(from, commit) do
    fn path ->
      case System.cmd("git", ["-C", from, "show", "#{commit}:#{path}"], stderr_to_stdout: true) do
        {bytes, 0} -> {:ok, bytes}
        _ -> :error
      end
    end
  end

  @doc "One item from an example file's bytes, without its version."
  def payload(entry, bytes, cfg, examples, commit) do
    text =
      Enum.reduce(entry["replace"] || %{}, bytes, fn {from, to}, t ->
        String.replace(t, from, to)
      end)

    strip = entry["strip"] || []
    docs = text |> Items.parse_yaml!() |> Enum.map(&clean(&1, strip)) |> Enum.reject(&is_nil/1)

    forbidden =
      for d <- docs ++ Enum.flat_map(docs, &inner/1),
          d["kind"] in Validate.forbidden_kinds(),
          do: d["kind"]

    if forbidden != [],
      do:
        raise(
          "#{entry["path"]}: holds #{Enum.join(Enum.uniq(forbidden), ", ")}; list it in strip or keep the file out"
        )

    agents = docs |> Items.agents() |> Enum.map(& &1["metadata"]["name"])

    models =
      Map.new(agents, fn name ->
        spec =
          get_in(entry, ["models", name]) ||
            raise("#{entry["path"]}: no tier for Agent #{name} in items.json")

        {name, Importer.model(spec, examples)}
      end)

    item =
      %{
        "kind" => entry["kind"] || kind(docs),
        "title" => entry["title"],
        "description" => entry["description"],
        "categories" => entry["categories"],
        "keywords" => entry["keywords"] || [],
        "publisher" => "ragentic",
        "provides" => entry["provides"] || [],
        "requires" => %{
          "ragentic" => entry["requires"] || cfg["requires"] || ">= 2026.11.0",
          "items" => [],
          "connectors" => entry["connectors"] || []
        },
        "params" => params(entry, docs)
      }

    %{
      "kind" => "item",
      "id" => entry["id"],
      "item" => item,
      "manifests" => docs,
      "models" => models,
      "provenance" => %{
        "repository" => cfg["repository"],
        "path" => entry["path"],
        "commit" => commit,
        "sha256" => Importer.sha256(bytes)
      },
      "rights" => %{"license" => cfg["license"], "attribution" => "ragentic"}
    }
  end

  defp inner(%{"kind" => "Package", "spec" => %{"manifests" => m}}) when is_list(m), do: m
  defp inner(_), do: []

  defp clean(%{"kind" => kind} = doc, strip) do
    if kind in strip do
      nil
    else
      doc
      |> scrub()
      |> then(fn
        %{"kind" => "Package", "spec" => %{"manifests" => m}} = d when is_list(m) ->
          put_in(
            d,
            ["spec", "manifests"],
            m |> Enum.map(&clean(&1, strip)) |> Enum.reject(&is_nil/1)
          )

        d ->
          d
      end)
    end
  end

  defp clean(_, _), do: nil

  defp scrub(%{"kind" => "Agent", "spec" => spec} = d) when is_map(spec),
    do: %{d | "spec" => Map.drop(spec, ["model", "fallback"])}

  defp scrub(%{"kind" => "Team", "spec" => %{"spawn" => %{} = spawn} = spec} = d),
    do: %{d | "spec" => %{spec | "spawn" => Map.delete(spawn, "model")}}

  defp scrub(d), do: d

  defp kind(docs) do
    case docs |> Enum.map(& &1["kind"]) |> Enum.uniq() do
      [one] -> one
      _ -> "Bundle"
    end
  end

  # the workspace most manifests live in is the `workspace` param's default
  defp params(entry, docs) do
    ws =
      docs
      |> Enum.map(&get_in(&1, ["metadata", "namespace"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.max_by(&elem(&1, 1), fn -> nil end)

    base =
      if ws,
        do: %{
          "workspace" => %{
            "default" => elem(ws, 0),
            "description" => "the workspace its manifests live in"
          }
        },
        else: %{}

    Map.merge(base, entry["params"] || %{})
  end
end
