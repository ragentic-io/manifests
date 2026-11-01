defmodule Manifests.Registry.Manifest do
  @moduledoc """
  One application in the catalog, with the listing metadata people search and
  filter by. `latest_version`/`latest_digest` point at the version the newest
  signed index lists; older versions stay reachable through `versions`.
  """
  use Ash.Resource,
    otp_app: :manifests,
    domain: Manifests.Registry,
    data_layer: AshPostgres.DataLayer

  require Ash.Query

  postgres do
    table "manifests"
    repo Manifests.Repo

    custom_indexes do
      index [:labels], using: "gin"
    end
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      upsert? true

      upsert_fields [
        :title,
        :protocol,
        :catalog,
        :labels,
        :description,
        :endpoint,
        :logo,
        :latest_version,
        :latest_digest,
        :operation_count,
        :search_text,
        :listed,
        :updated_at
      ]

      accept [
        :id,
        :title,
        :protocol,
        :catalog,
        :labels,
        :description,
        :endpoint,
        :logo,
        :latest_version,
        :latest_digest,
        :operation_count,
        :search_text,
        :listed
      ]
    end

    update :unlist do
      accept []
      change set_attribute(:listed, false)
    end

    read :search do
      description """
      Free-text search over id, title, endpoint, labels and operation names, narrowed
      by labels (all must match), protocol and catalog.
      """

      argument :filters, :map, default: %{}

      pagination offset?: true,
                 required?: false,
                 default_limit: 48,
                 max_page_size: 200,
                 countable: :by_default

      prepare {Manifests.Registry.Manifest.Search, []}
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true, writable?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :protocol, :string, allow_nil?: false, public?: true

    attribute :catalog, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A(published|draft)\z/]

    attribute :labels, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :description, :string, public?: true
    attribute :endpoint, :string, public?: true
    attribute :logo, :string, public?: true
    attribute :latest_version, :string, allow_nil?: false, public?: true
    attribute :latest_digest, :string, allow_nil?: false, public?: true
    attribute :operation_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :search_text, :string
    attribute :listed, :boolean, allow_nil?: false, default: true, public?: true

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true, writable?: true
  end

  relationships do
    has_many :versions, Manifests.Registry.Version do
      destination_attribute :manifest_id
      sort inserted_at: :desc
    end
  end
end

defmodule Manifests.Registry.Manifest.Search do
  @moduledoc false
  use Ash.Resource.Preparation
  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    filters = Ash.Query.get_argument(query, :filters) || %{}

    query
    |> Ash.Query.filter(listed == true)
    |> text(filters[:q])
    |> labels(filters[:labels])
    |> eq(:protocol, filters[:protocol])
    |> eq(:catalog, filters[:catalog])
    |> Ash.Query.sort(sort(filters[:sort]))
  end

  defp text(query, q) when is_binary(q) and q != "" do
    Enum.reduce(String.split(String.downcase(q)), query, fn term, query ->
      Ash.Query.filter(query, contains(search_text, ^term))
    end)
  end

  defp text(query, _), do: query

  defp labels(query, [_ | _] = labels),
    do: Ash.Query.filter(query, fragment("? @> ?", labels, ^labels))

  defp labels(query, _), do: query

  defp eq(query, _field, nil), do: query
  defp eq(query, field, value), do: Ash.Query.filter(query, ^Ash.Expr.ref(field) == ^value)

  defp sort("updated"), do: [updated_at: :desc, title: :asc]
  defp sort("operations"), do: [operation_count: :desc, title: :asc]
  defp sort(_), do: [title: :asc, id: :asc]
end
