defmodule ManifestsWeb.RegistryController do
  @moduledoc """
  The signed transport ragentic's registry client reads (`https://manifests.ragentic.io/v1`).
  Bodies are served byte for byte as they were signed; clients verify them
  against their own pinned root, so these routes must never re-encode anything.
  """
  use ManifestsWeb, :controller
  require Ash.Query
  alias Manifests.Registry
  alias Manifests.Registry.Version

  def index(conn, _), do: snapshot(conn, "index")
  def browse_index(conn, _), do: snapshot(conn, "browse_index")
  def bundle(conn, %{"digest" => digest}), do: bundle(conn, digest, "published")
  def browse_bundle(conn, %{"digest" => digest}), do: bundle(conn, digest, "draft")

  def healthz(conn, _), do: send_resp(conn, 200, "ok")

  defp snapshot(conn, kind) do
    case Registry.latest_snapshot(kind) do
      {:ok, %{body: body}} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, body)

      _ ->
        unavailable(conn)
    end
  end

  defp bundle(conn, digest, catalog) do
    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         %Version{bundle: body} <-
           Version
           |> Ash.Query.filter(digest == ^digest and catalog == ^catalog)
           |> Ash.Query.select([:bundle])
           |> Ash.read_one!() do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, body)
    else
      _ -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  defp unavailable(conn) do
    conn
    |> put_resp_header("retry-after", "10")
    |> put_status(503)
    |> json(%{error: "catalog_not_loaded"})
  end
end
