defmodule ManifestsWeb.ApiTest do
  use ManifestsWeb.ConnCase, async: true
  alias Manifests.{Catalog, CatalogFixture}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    dir =
      CatalogFixture.write!(tmp, [
        %{id: "pay", version: "1.0.0", categories: ["finance"]},
        %{id: "tube", version: "2.0.0", catalog: "draft", categories: ["media"]}
      ])

    {:ok, _} = Catalog.import_dir(dir)
    %{dir: dir}
  end

  test "legacy transport serves the signed bytes untouched", %{conn: conn, dir: dir} do
    assert response(get(conn, "/v1/index.json"), 200) == File.read!(Path.join(dir, "index.json"))
    assert response(get(conn, "/v1/browse-index.json"), 200) == File.read!(Path.join(dir, "browse-index.json"))

    [bundle] = File.ls!(Path.join(dir, "bundles"))
    digest = Path.rootname(bundle)
    conn = get(conn, "/v1/bundles/#{digest}")
    assert response(conn, 200) == File.read!(Path.join([dir, "bundles", bundle]))
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

    # A published bundle isn't served from the drafts path, and vice versa.
    assert json_response(get(build_conn(), "/v1/browse-bundles/#{digest}"), 404)
    assert response(get(build_conn(), "/healthz"), 200) == "ok"
  end

  test "a manifest request must name its version", %{conn: conn} do
    body = json_response(get(conn, "/api/v1/manifests/pay"), 400)
    assert body["error"] == "version_required"

    assert %{"version" => %{"version" => "1.0.0", "latest" => true, "digest" => digest}, "payload" => %{"graph" => _}} =
             json_response(get(build_conn(), "/api/v1/manifests/pay?version=latest"), 200)

    assert %{"version" => %{"digest" => ^digest}} =
             json_response(get(build_conn(), "/api/v1/manifests/pay?version=sha256:#{digest}"), 200)

    assert json_response(get(build_conn(), "/api/v1/manifests/pay/bundle"), 400)["error"] == "version_required"
    conn = get(build_conn(), "/api/v1/manifests/pay/bundle?version=1.0.0")
    assert get_resp_header(conn, "x-manifest-digest") == [digest]
    assert json_response(get(build_conn(), "/api/v1/manifests/pay?version=0.0.1"), 404)["error"] == "version_not_found"
  end

  test "search, labels and versions", %{conn: conn} do
    assert %{"total" => 1, "manifests" => [%{"id" => "tube"}]} =
             json_response(get(conn, "/api/v1/manifests?labels=category:media"), 200)

    assert %{"total" => 0} =
             json_response(get(build_conn(), "/api/v1/manifests?labels=category:media,catalog:published"), 200)

    assert %{"total" => 1, "manifests" => [%{"id" => "pay"}]} =
             json_response(get(build_conn(), "/api/v1/manifests?q=pay"), 200)

    %{"labels" => labels} = json_response(get(build_conn(), "/api/v1/labels"), 200)
    assert %{"label" => "category:finance", "count" => 1} in labels["category"]

    assert %{"latest" => "1.0.0", "versions" => [%{"version" => "1.0.0", "current_root" => true}]} =
             json_response(get(build_conn(), "/api/v1/manifests/pay/versions"), 200)
  end
end
