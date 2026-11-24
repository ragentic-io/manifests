defmodule ManifestsWeb.ItemsApiTest do
  use ManifestsWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Manifests.{Catalog, CatalogFixture}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    CatalogFixture.write!(tmp, [%{id: "pay", version: "1.0.0", categories: ["finance"]}])

    CatalogFixture.write_items!(tmp, [
      %{
        id: "diagram-designer",
        version: "1.0.0",
        provides: ["agent-label:diagrams.ragentic.io/designer"]
      },
      %{
        id: "agency-team-design",
        version: "1.1.0",
        kind: "Team",
        title: "Design team",
        publisher: "agency-agents",
        categories: ["design"],
        tiers: %{
          "design-lead" => %{"tier" => "large", "tools" => true},
          "ui" => %{"tier" => "medium", "vision" => true}
        }
      }
    ])

    {:ok, _} = Catalog.import_dir(tmp)
    %{dir: tmp}
  end

  test "the signed items index and bundles are served byte for byte", %{conn: conn, dir: dir} do
    assert response(get(conn, "/v1/items-index.json"), 200) ==
             File.read!(Path.join(dir, "items-index.json"))

    [file | _] = File.ls!(Path.join(dir, "item-bundles"))
    conn = get(build_conn(), "/v1/item-bundles/#{Path.rootname(file)}")
    assert response(conn, 200) == File.read!(Path.join([dir, "item-bundles", file]))
    assert json_response(get(build_conn(), "/v1/item-bundles/#{String.duplicate("0", 64)}"), 404)

    # app bundles and item bundles never answer for each other
    assert json_response(get(build_conn(), "/v1/bundles/#{Path.rootname(file)}"), 404)
  end

  test "search and filter items by kind, category, publisher and tier", %{conn: conn} do
    assert %{"total" => 2, "items" => items} = json_response(get(conn, "/api/v1/items"), 200)
    assert Enum.map(items, & &1["id"]) == ["diagram-designer", "agency-team-design"]

    ids = fn query ->
      json_response(get(build_conn(), "/api/v1/items?" <> query), 200)["items"]
      |> Enum.map(& &1["id"])
    end

    assert ids.("kind=Team") == ["agency-team-design"]
    assert ids.("category=design") == ["agency-team-design"]
    assert ids.("publisher=ragentic") == ["diagram-designer"]
    assert ids.("tier=medium") == ["agency-team-design"]
    assert ids.("tier=large%2Btools") |> Enum.sort() == ["agency-team-design", "diagram-designer"]
    assert ids.("q=diagram") == ["diagram-designer"]
  end

  test "an item shows its manifests and models; versions and bundle", %{conn: conn} do
    body = json_response(get(conn, "/api/v1/items/agency-team-design"), 200)
    assert body["item"]["kind"] == "Team"
    assert body["item"]["install"] == "ragentic install agency-team-design"
    assert %{"design-lead" => %{"tier" => "large"}} = body["payload"]["models"]
    assert length(body["payload"]["manifests"]) == 2

    assert %{"versions" => [%{"version" => "1.1.0", "listed" => true}]} =
             json_response(get(build_conn(), "/api/v1/items/agency-team-design/versions"), 200)

    conn = get(build_conn(), "/api/v1/items/diagram-designer/bundle")
    assert %{"envelope" => _} = Jason.decode!(response(conn, 200))
    assert json_response(get(build_conn(), "/api/v1/items/nope"), 404)
  end

  test "a newer index unlists items it no longer names", %{dir: dir} do
    CatalogFixture.write_items!(dir, [%{id: "diagram-designer", version: "1.0.1"}], sequence: 2)
    {:ok, _} = Catalog.import_dir(dir)

    assert %{"items" => [%{"id" => "diagram-designer", "version" => "1.0.1"}]} =
             json_response(get(build_conn(), "/api/v1/items"), 200)

    # and an older one never brings them back
    CatalogFixture.write_items!(
      dir,
      [%{id: "agency-team-design", version: "1.1.0", kind: "Agent"}],
      sequence: 1
    )

    {:ok, _} = Catalog.import_dir(dir)
    assert %{"total" => 1} = json_response(get(build_conn(), "/api/v1/items"), 200)
  end

  test "the items page lists items by kind and filters by kind", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/items")
    assert has_element?(view, "#items-Agent #item-diagram-designer")
    assert has_element?(view, "#items-Team #item-agency-team-design")

    view |> element("#kind-Team") |> render_click()
    refute has_element?(view, "#item-diagram-designer")
    assert has_element?(view, "#item-agency-team-design")
  end
end
