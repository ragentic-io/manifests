defmodule Manifests.CatalogImportTest do
  use Manifests.DataCase, async: true
  alias Manifests.{Catalog, CatalogFixture, Registry}
  alias Manifests.Registry.Lookup

  @moduletag :tmp_dir

  defp catalog(tmp_dir, name, apps, opts \\ []),
    do: CatalogFixture.write!(Path.join(tmp_dir, name), apps, opts)

  test "imports a verified catalog with labels and search text", %{tmp_dir: tmp} do
    dir =
      catalog(tmp, "v1", [
        %{id: "pay", version: "1.0.0", title: "Pay Co", categories: ["finance"]},
        %{id: "tube", version: "2.0.0", catalog: "draft", categories: ["media"], operations: [{"post", "/videos", "UploadVideo"}]}
      ])

    assert {:ok, [{"index", %{new: 1}}, {"browse_index", %{new: 1}}]} = Catalog.import_dir(dir)

    pay = Registry.get_manifest!("pay")
    assert pay.title == "Pay Co"
    assert "category:finance" in pay.labels
    assert "catalog:published" in pay.labels
    assert "auth:static_bearer" in pay.labels

    assert ["tube"] == ids(%{labels: ["category:media"]})
    assert ["tube"] == ids(%{q: "uploadvideo"})
    assert ["pay"] == ids(%{q: "finance pay"})
    assert [] == ids(%{labels: ["category:media", "catalog:published"]})
    assert ["pay"] == ids(%{catalog: "published"})

    # Re-importing the same catalog adds nothing.
    assert {:ok, [{"index", %{new: 0}}, {"browse_index", %{new: 0}}]} = Catalog.import_dir(dir)
  end

  test "keeps every version and resolves latest, a version, or a digest", %{tmp_dir: tmp} do
    now = System.system_time(:second)
    {:ok, _} = Catalog.import_dir(catalog(tmp, "a", [%{id: "pay", version: "1.0.0", not_before: now - 600}], sequence: 1))
    {:ok, _} = Catalog.import_dir(catalog(tmp, "b", [%{id: "pay", version: "1.1.0"}], sequence: 2))

    assert {:error, :version_required} = Lookup.resolve("pay", nil)
    assert {:ok, m, latest} = Lookup.resolve("pay", "latest")
    assert latest.version == "1.1.0" and m.latest_version == "1.1.0"
    assert {:ok, _, old} = Lookup.resolve("pay", "1.0.0")
    assert old.version == "1.0.0"
    assert {:ok, _, by_digest} = Lookup.resolve("pay", "sha256:" <> old.digest)
    assert by_digest.id == old.id
    assert {:error, :version_not_found} = Lookup.resolve("pay", "9.9.9")
    assert {:error, :not_found} = Lookup.resolve("nope", "latest")
    assert ["1.1.0", "1.0.0"] == Enum.map(Lookup.versions("pay"), & &1.version)
  end

  test "an older index never rolls the listing back", %{tmp_dir: tmp} do
    {:ok, _} = Catalog.import_dir(catalog(tmp, "new", [%{id: "pay", version: "2.0.0"}], sequence: 5))
    {:ok, _} = Catalog.import_dir(catalog(tmp, "old", [%{id: "pay", version: "1.0.0"}], sequence: 3))

    assert Registry.get_manifest!("pay").latest_version == "2.0.0"
    assert {:ok, %{sequence: 5}} = Registry.latest_snapshot("index")
    # The older bundle is still kept as history.
    assert {:ok, _, %{version: "1.0.0"}} = Lookup.resolve("pay", "1.0.0")
  end

  test "rejects a catalog signed by another key", %{tmp_dir: tmp} do
    dir = catalog(tmp, "v1", [%{id: "pay", version: "1.0.0"}])
    {other, _} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:ok, [{"index", :untrusted_index}, {"browse_index", :untrusted_index}]} =
             Manifests.Catalog.Import.run(Manifests.Catalog.Import.dir(dir),
               root: other,
               registry: "manifests.ragentic.io"
             )

    assert {:error, _} = Registry.get_manifest("pay")
  end

  defp ids(filters) do
    filters
    |> Registry.search_manifests!(page: false)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end
end
