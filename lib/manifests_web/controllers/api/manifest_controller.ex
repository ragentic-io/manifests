defmodule ManifestsWeb.Api.ManifestController do
  @moduledoc """
  Read API over the verified registry. Anything that returns a manifest must name
  its version (`?version=latest`, `?version=<version>` or `?version=sha256:<digest>`),
  so a request always says which signed bundle it means.
  """
  use ManifestsWeb, :controller
  alias Manifests.Registry
  alias Manifests.Registry.Lookup

  @max_limit 200

  def index(conn, params) do
    filters = Lookup.filters(params)
    limit = params |> int("limit", 48) |> min(@max_limit) |> max(1)
    offset = params |> int("offset", 0) |> max(0)
    page = Registry.search_manifests!(filters, page: [limit: limit, offset: offset, count: true])

    json(conn, %{
      total: page.count,
      limit: limit,
      offset: offset,
      filters: filters,
      manifests: Enum.map(page.results, &summary(conn, &1))
    })
  end

  def labels(conn, params) do
    facets = Lookup.facets(Lookup.filters(params))

    json(conn, %{
      labels:
        for(
          {key, pairs} <- facets,
          into: %{},
          do: {key, Enum.map(pairs, fn {l, n} -> %{label: l, count: n} end)}
        )
    })
  end

  def show(conn, %{"id" => id} = params) do
    with {:ok, manifest, version} <- Lookup.resolve(id, params["version"]) do
      payload = Lookup.payload(version)

      json(conn, %{
        manifest: summary(conn, manifest),
        version: version_json(conn, manifest, version),
        payload:
          Map.take(
            payload,
            ~w(manifest graph setup provenance rights readiness review_required a2ui)
          )
      })
    else
      error -> error(conn, id, error)
    end
  end

  def bundle(conn, %{"id" => id} = params) do
    with {:ok, _manifest, version} <- Lookup.resolve(id, params["version"]) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("x-manifest-digest", version.digest)
      |> put_resp_header(
        "cache-control",
        if(params["version"] == "latest",
          do: "no-cache",
          else: "public, max-age=31536000, immutable"
        )
      )
      |> send_resp(200, version.bundle)
    else
      error -> error(conn, id, error)
    end
  end

  def versions(conn, %{"id" => id}) do
    case Registry.get_manifest(id) do
      {:ok, manifest} ->
        json(conn, %{
          id: id,
          latest: manifest.latest_version,
          versions: Enum.map(Lookup.versions(id), &version_json(conn, manifest, &1))
        })

      _ ->
        error(conn, id, {:error, :not_found})
    end
  end

  defp summary(conn, m) do
    %{
      id: m.id,
      title: m.title,
      protocol: m.protocol,
      catalog: m.catalog,
      labels: m.labels,
      endpoint: m.endpoint,
      logo: m.logo,
      latest_version: m.latest_version,
      latest_digest: m.latest_digest,
      operations: m.operation_count,
      url: url(conn, ~p"/apps/#{m.id}?#{[version: "latest"]}"),
      api: url(conn, ~p"/api/v1/manifests/#{m.id}?#{[version: "latest"]}")
    }
  end

  defp version_json(conn, m, v) do
    %{
      version: v.version,
      digest: v.digest,
      latest: v.digest == m.latest_digest,
      catalog: v.catalog,
      readiness: v.readiness,
      signed_by: v.signed_by,
      current_root: v.signed_by == Manifests.Catalog.root_key_id(),
      not_before: v.not_before,
      expires: v.expires,
      sequence: v.last_sequence,
      commit: v.commit,
      url: url(conn, ~p"/apps/#{m.id}?#{[version: "sha256:" <> v.digest]}"),
      bundle: url(conn, ~p"/api/v1/manifests/#{m.id}/bundle?#{[version: "sha256:" <> v.digest]}")
    }
  end

  defp error(conn, id, {:error, :version_required}) do
    conn
    |> put_status(400)
    |> json(%{
      error: "version_required",
      message: "Name a version: ?version=latest, ?version=<version> or ?version=sha256:<digest>.",
      versions: url(conn, ~p"/api/v1/manifests/#{id}/versions")
    })
  end

  defp error(conn, id, {:error, :version_not_found}) do
    conn
    |> put_status(404)
    |> json(%{
      error: "version_not_found",
      versions: url(conn, ~p"/api/v1/manifests/#{id}/versions")
    })
  end

  defp error(conn, _id, _), do: conn |> put_status(404) |> json(%{error: "not_found"})

  defp int(params, key, default) do
    case Integer.parse(to_string(params[key] || "")) do
      {n, ""} -> n
      _ -> default
    end
  end
end
