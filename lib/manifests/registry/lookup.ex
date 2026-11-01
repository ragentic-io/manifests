defmodule Manifests.Registry.Lookup do
  @moduledoc """
  Resolves the `version` every manifest request must name: `latest`, a version
  string (its newest signing), or `sha256:<digest>` for one exact signed bundle.
  """
  require Ash.Query
  alias Manifests.Registry
  alias Manifests.Registry.{Manifest, Version}

  @digest ~r/\Asha256:([0-9a-f]{64})\z/

  @type error :: :version_required | :not_found | :version_not_found

  @spec resolve(String.t(), String.t() | nil) ::
          {:ok, Manifest.t(), Version.t()} | {:error, error}
  def resolve(_id, version) when version in [nil, ""], do: {:error, :version_required}

  def resolve(id, version) do
    with {:ok, manifest} <- fetch_manifest(id),
         {:ok, v} <- fetch_version(manifest, version) do
      {:ok, manifest, v}
    end
  end

  defp fetch_manifest(id) do
    case Registry.get_manifest(id) do
      {:ok, m} -> {:ok, m}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_version(manifest, "latest"), do: by_digest(manifest, manifest.latest_digest)

  defp fetch_version(manifest, version) do
    case Regex.run(@digest, version) do
      [_, digest] ->
        by_digest(manifest, digest)

      nil ->
        Version
        |> Ash.Query.filter(manifest_id == ^manifest.id and version == ^version)
        |> Ash.Query.sort(not_before: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one()
        |> found()
    end
  end

  defp by_digest(manifest, digest) do
    Version
    |> Ash.Query.filter(manifest_id == ^manifest.id and digest == ^digest)
    |> Ash.read_one()
    |> found()
  end

  defp found({:ok, %Version{} = v}), do: {:ok, v}
  defp found(_), do: {:error, :version_not_found}

  @doc "Version history, newest signing first, without the bundle bodies."
  def versions(id), do: Registry.versions_of!(id)

  @doc """
  Label counts among manifests matching every filter except the labels
  themselves, plus the selected labels (so a chosen label never vanishes).
  """
  def facets(filters) do
    rows =
      Manifest
      |> Ash.Query.for_read(:search, %{filters: Map.delete(filters, :labels)})
      |> Ash.Query.select([:labels])
      |> Ash.read!(page: false)

    selected = filters[:labels] || []

    rows
    |> Enum.filter(fn m -> Enum.all?(selected, &(&1 in m.labels)) end)
    |> Enum.flat_map(& &1.labels)
    |> Enum.frequencies()
    |> then(fn counts -> Enum.reduce(selected, counts, &Map.put_new(&2, &1, 0)) end)
    |> Enum.group_by(fn {label, _} -> label |> String.split(":", parts: 2) |> hd() end)
    |> Map.new(fn {key, pairs} ->
      {key, Enum.sort_by(pairs, fn {label, n} -> {-n, label} end)}
    end)
  end

  @doc "Parse the filters shared by the API and the catalog page from query params."
  def filters(params) do
    %{
      q: blank(params["q"]),
      labels:
        [params["labels"], params["label"]]
        |> List.flatten()
        |> Enum.reject(&is_nil/1)
        |> List.wrap()
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq(),
      protocol: blank(params["protocol"]),
      catalog: blank(params["catalog"]),
      sort: blank(params["sort"])
    }
  end

  defp blank(nil), do: nil
  defp blank(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
  defp blank(_), do: nil

  @doc "Decoded bundle payload (manifest, graph, setup, provenance, ...)."
  def payload(%Version{bundle: bundle} = v) when is_binary(bundle) and bundle != "",
    do: Manifests.Catalog.Import.payload(v)

  def payload(%Version{id: id}),
    do: Version |> Ash.Query.filter(id == ^id) |> Ash.read_one!() |> payload()
end
