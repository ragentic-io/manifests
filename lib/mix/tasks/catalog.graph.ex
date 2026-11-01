defmodule Mix.Tasks.Catalog.Graph do
  @shortdoc "Regenerate catalog OpenAPI operation graphs"
  @moduledoc """
  Regenerate the operation graph of one or more OpenAPI applications from their
  embedded definitions, and rewrite their `manifest.json` and `MANIFEST.md`.

      mix catalog.graph ID [ID ...] [--root DIR]

  Only OpenAPI graphs are generated; other protocols' graphs are edited by hand.
  """
  use Mix.Task

  alias Manifests.CatalogTools.{Catalog, CLI, Error, Graph, Json, Py}

  @usage "mix catalog.graph ID [ID ...] [--root DIR]"

  @impl Mix.Task
  def run(args) do
    {_opts, ids, c} = CLI.parse!(args, [], @usage)
    if ids == [], do: CLI.usage_error!(@usage, "the following arguments are required: ids")

    CLI.run(fn ->
      {signed, _} = Catalog.signed_state(c)

      # Generate in parallel; write and report in order, stopping at the first
      # application that can't be generated, like the Python loop.
      ids
      |> Catalog.pstream(&generate(c, &1, signed))
      |> Enum.each(fn
        {:error, msg} ->
          raise Error, msg

        {:ok, app_id, manifest_json, manifest_md, nodes} ->
          folder = Path.join(Catalog.apps_dir(c), app_id)
          File.mkdir_p!(folder)
          Catalog.write!(Path.join(folder, "manifest.json"), manifest_json)
          Catalog.write!(Path.join(folder, "MANIFEST.md"), manifest_md)
          IO.puts("#{app_id}: #{nodes} nodes")
      end)
    end)
  end

  defp generate(c, app_id, signed) do
    {payload, listing, _} = Catalog.load_app(c, app_id)
    protocol = Json.get(payload, "protocol")

    if protocol == "openapi" do
      document =
        Enum.reduce(~w(manifest spec base specification document), payload, &Json.fetch!(&2, &1))

      graph = Graph.openapi_graph(app_id, document)
      payload = Json.put(payload, "graph", graph)

      {:ok, app_id, Json.pretty(payload),
       Catalog.manifest_md(c, app_id, payload, listing, signed), length(graph["nodes"])}
    else
      {:error,
       "#{app_id}: only OpenAPI graphs are generated; edit graph by hand for #{Py.str(protocol)}"}
    end
  end
end
