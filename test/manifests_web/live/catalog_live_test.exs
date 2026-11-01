defmodule ManifestsWeb.CatalogLiveTest do
  use ManifestsWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Manifests.{Catalog, CatalogFixture}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    now = System.system_time(:second)

    {:ok, _} =
      Catalog.import_dir(
        CatalogFixture.write!(Path.join(tmp, "a"), [%{id: "pay", version: "1.0.0", categories: ["finance"], not_before: now - 600}], sequence: 1)
      )

    {:ok, _} =
      Catalog.import_dir(
        CatalogFixture.write!(
          Path.join(tmp, "b"),
          [
            %{id: "pay", version: "1.1.0", title: "Pay Co", categories: ["finance"], operations: [{"get", "/charges", "ListCharges"}, {"post", "/charges", "CreateCharge"}]},
            %{id: "tube", version: "2.0.0", catalog: "draft", categories: ["media"]}
          ],
          sequence: 2
        )
      )

    :ok
  end

  test "search and label filters live in the URL", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/?labels=category:media")
    assert html =~ "1 application"
    assert has_element?(view, "a[href^='/apps/tube']")
    refute has_element?(view, "a[href^='/apps/pay']")

    view |> element("form[role=search]") |> render_change(%{"q" => "charge"})
    assert_patch(view, "/?labels=category%3Amedia&q=charge")
    assert render(view) =~ "0 applications"

    {:ok, view, _} = live(conn, ~p"/?q=charge")
    assert has_element?(view, "a[href^='/apps/pay']")
  end

  test "a manifest link without a version is rewritten to latest", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/apps/pay?version=latest"}}} = live(conn, ~p"/apps/pay")
    {:ok, _view, html} = live(conn, ~p"/apps/pay?version=latest")
    assert html =~ "Pay Co"
    refute html =~ "The latest is"
  end

  test "an older version, a tab and an operation can be deep-linked", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/apps/pay?version=1.0.0&tab=versions")
    assert html =~ "The latest is"
    assert has_element?(view, "[role=tab][aria-selected=true]", "Versions")

    {:ok, view, html} = live(conn, ~p"/apps/pay?version=latest&op=operation:post:/charges")
    assert html =~ "CreateCharge"
    assert has_element?(view, "[role=tab][aria-selected=true]", "Operations")

    view |> element("form[phx-change=version]") |> render_change(%{"version" => "1.0.0"})
    assert_patch(view)
    assert render(view) =~ "The latest is"
  end

  test "unknown apps and versions fall back", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/?q=nope"}}} = live(conn, ~p"/apps/nope?version=latest")
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/apps/pay?version=9.9.9")
    assert to =~ "version=latest"
  end
end
