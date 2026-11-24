defmodule ManifestsWeb.Api.ItemController do
  @moduledoc """
  Read API over verified items of any kind (Agents, Teams, Workflows, Sites,
  Packages, …). Rows are only written after their signatures check out.

      GET /api/v1/items?q=&kind=&category=&publisher=&tier=&limit=&offset=
      GET /api/v1/items/:id              the listed version, its manifests and models
      GET /api/v1/items/:id/versions
      GET /api/v1/items/:id/bundle       the signed bundle, byte for byte
  """
  use ManifestsWeb, :controller
  alias Manifests.Catalog.Import
  alias Manifests.Registry
  alias Manifests.Registry.Item

  @max_limit 200

  def index(conn, params) do
    limit = params |> int("limit", 48) |> min(@max_limit) |> max(1)
    offset = params |> int("offset", 0) |> max(0)

    page =
      Registry.search_items!(
        params["q"],
        params["kind"],
        params["category"],
        params["publisher"],
        params["tier"],
        page: [limit: limit, offset: offset, count: true]
      )

    json(conn, %{
      total: page.count,
      limit: limit,
      offset: offset,
      items: Enum.map(page.results, &summary(conn, &1))
    })
  end

  def show(conn, %{"id" => id}) do
    case Registry.listed_item(id) do
      {:ok, item} ->
        payload = Import.payload(item)

        json(conn, %{
          item: summary(conn, item),
          payload: Map.take(payload, ~w(item manifests models provenance rights))
        })

      _ ->
        not_found(conn, id)
    end
  end

  def versions(conn, %{"id" => id}) do
    case Registry.item_versions!(id) do
      [] -> not_found(conn, id)
      versions -> json(conn, %{id: id, versions: Enum.map(versions, &version_json/1)})
    end
  end

  def bundle(conn, %{"id" => id}) do
    case Registry.listed_item(id) do
      {:ok, item} ->
        Manifests.Analytics.record(id, item.digest)

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("x-manifest-digest", item.digest)
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, item.bundle)

      _ ->
        not_found(conn, id)
    end
  end

  defp summary(conn, %Item{} = i) do
    %{
      id: i.item_id,
      version: i.version,
      digest: i.digest,
      kind: i.kind,
      title: i.title,
      description: i.description,
      publisher: i.publisher,
      categories: i.categories,
      keywords: i.keywords,
      provides: i.provides,
      tiers: i.tiers,
      count: i.count,
      logo: i.logo,
      install: "ragentic install #{i.item_id}",
      links: %{
        self: url(conn, ~p"/api/v1/items/#{i.item_id}"),
        bundle: url(conn, ~p"/v1/item-bundles/#{i.digest}")
      }
    }
  end

  defp version_json(%Item{} = i) do
    %{
      version: i.version,
      digest: i.digest,
      listed: i.listed,
      signed_by: i.signed_by,
      not_before: i.not_before,
      expires: i.expires,
      first_sequence: i.first_sequence,
      last_sequence: i.last_sequence,
      commit: i.commit
    }
  end

  defp not_found(conn, id),
    do: conn |> put_status(404) |> json(%{error: "not_found", id: id})

  defp int(params, key, default) do
    case Integer.parse(to_string(params[key] || "")) do
      {n, ""} -> n
      _ -> default
    end
  end
end
