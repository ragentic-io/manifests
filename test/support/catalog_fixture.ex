defmodule Manifests.CatalogFixture do
  @moduledoc """
  Writes a small catalog signed with a throwaway root (pinned in config/test.exs),
  laid out like `catalog/`: indexes, bundles, MANIFEST.md front matter.
  """
  alias Manifests.Trust

  @seed :binary.copy(<<7>>, 32)

  def keys, do: :crypto.generate_key(:eddsa, :ed25519, @seed)
  def root, do: elem(keys(), 0)

  @doc """
  `apps` is a list of maps with `:id`, `:version` and optionally `:title`,
  `:catalog` ("published"/"draft"), `:categories`, `:operations`, `:not_before`.
  """
  def write!(dir, apps, opts \\ []) do
    {_pub, priv} = keys()
    now = Keyword.get(opts, :now, System.system_time(:second))
    File.mkdir_p!(Path.join(dir, "bundles"))
    File.mkdir_p!(Path.join(dir, "browse-bundles"))

    File.write!(
      Path.join(dir, "categories.json"),
      ~s([{"id": "finance", "title": "Finance & payments"}, {"id": "media", "title": "Media"}])
    )

    entries =
      for app <- apps do
        catalog = app[:catalog] || "published"
        nb = app[:not_before] || now - 60
        payload = bundle_payload(app, nb)
        envelope = Trust.sign(payload, priv)
        digest = Trust.digest(envelope)
        folder = if catalog == "published", do: "bundles", else: "browse-bundles"

        File.write!(
          Path.join([dir, folder, "#{digest}.json"]),
          Jason.encode!(%{"chain" => [], "envelope" => envelope})
        )

        File.mkdir_p!(Path.join([dir, "apps", app.id]))

        File.write!(Path.join([dir, "apps", app.id, "MANIFEST.md"]), """
        ---
        title: #{Jason.encode!(app[:title] || "App #{app.id}")}
        catalog: "#{catalog}"
        categories: #{Jason.encode!(app[:categories] || [])}
        ---
        # #{app.id}
        """)

        {catalog,
         %{
           "id" => app.id,
           "version" => app.version,
           "digest" => digest,
           "title" => app[:title] || "App #{app.id}",
           "protocol" => "openapi"
         }}
      end

    for {kind, file, catalog} <- [
          {"index", "index.json", "published"},
          {"browse_index", "browse-index.json", "draft"}
        ] do
      index = %{
        "kind" => kind,
        "registry" => "manifests.ragentic.io",
        "sequence" => Keyword.get(opts, :sequence, 1),
        "not_before" => now - 60,
        "expires" => now + 86_400,
        "entries" => for({^catalog, e} <- entries, do: e)
      }

      File.write!(Path.join(dir, file), Jason.encode!(Trust.sign(index, priv)))
    end

    dir
  end

  defp bundle_payload(app, nb) do
    ops = app[:operations] || [{"get", "/things", "ListThings"}]

    %{
      "kind" => "bundle",
      "app" => app.id,
      "version" => app.version,
      "protocol" => "openapi",
      "not_before" => nb,
      "expires" => nb + 86_400 * 90,
      "readiness" => "definition_imported",
      "manifest" => %{
        "apiVersion" => "ragentic.io/v1",
        "kind" => "ConnectorTemplate",
        "metadata" => %{"name" => app.id},
        "spec" => %{
          "base" => %{"endpoint" => "https://api.#{app.id}.example", "protocol" => "openapi"}
        }
      },
      "graph" => %{
        "nodes" =>
          [%{"id" => app.id, "kind" => "application"}] ++
            for {method, path, name} <- ops do
              %{
                "id" => "operation:#{method}:#{path}",
                "kind" => "operation",
                "method" => method,
                "path" => path,
                "name" => name,
                "summary" => "#{name} summary",
                "safe" => method == "get"
              }
            end,
        "edges" => []
      },
      "setup" => %{"credential" => %{"type" => "static_bearer"}},
      "a2ui" => %{},
      "provenance" => %{},
      "rights" => %{},
      "review_required" => %{"authentication" => true}
    }
  end
end
