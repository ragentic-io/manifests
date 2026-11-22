defmodule Manifests.Registry.Item do
  @moduledoc """
  One signed item bundle: an Agent, a Team with its agents, Workflows, a Site, a
  Package — anything that is a ragentic manifest (docs/registry.md in ragentic).
  The bundle file is kept byte for byte so clients re-verify it; the metadata
  is its signed items index entry. `listed` marks the versions the newest
  items index names (one per item id).
  """
  use Ash.Resource,
    otp_app: :manifests,
    domain: Manifests.Registry,
    data_layer: AshPostgres.DataLayer

  require Ash.Query

  postgres do
    table "registry_items"
    repo Manifests.Repo

    custom_indexes do
      index [:item_id]
      index [:listed]
    end
  end

  @summary [
    :id,
    :item_id,
    :version,
    :digest,
    :kind,
    :title,
    :description,
    :publisher,
    :categories,
    :keywords,
    :provides,
    :tiers,
    :count,
    :logo,
    :listed,
    :signed_by,
    :not_before,
    :expires,
    :first_sequence,
    :last_sequence,
    :commit,
    :inserted_at
  ]

  def summary_fields, do: @summary

  actions do
    defaults [:read]

    create :record do
      upsert? true
      upsert_identity :digest
      # the bundle never changes for a digest; only how widely it was published can
      upsert_fields [:last_sequence, :listed]

      accept [
        :item_id,
        :version,
        :digest,
        :kind,
        :title,
        :description,
        :publisher,
        :categories,
        :keywords,
        :provides,
        :tiers,
        :sizes,
        :count,
        :logo,
        :bundle,
        :search_text,
        :listed,
        :signed_by,
        :not_before,
        :expires,
        :first_sequence,
        :last_sequence,
        :commit
      ]
    end

    update :list do
      accept [:listed, :last_sequence]
    end

    read :search do
      description "Listed items: free text over id, title, description, keywords and categories; kind, category, publisher and tier filters."
      argument :q, :string
      argument :kind, :string
      argument :category, :string
      argument :publisher, :string
      argument :tier, :string

      pagination offset?: true,
                 required?: false,
                 default_limit: 48,
                 max_page_size: 200,
                 countable: :by_default

      filter expr(listed == true)

      prepare fn query, _ ->
        args = query.arguments

        query
        |> then(&if blank?(args[:kind]), do: &1, else: Ash.Query.filter(&1, kind == ^args.kind))
        |> then(
          &if blank?(args[:publisher]),
            do: &1,
            else: Ash.Query.filter(&1, publisher == ^args.publisher)
        )
        |> then(
          &if blank?(args[:category]),
            do: &1,
            else: Ash.Query.filter(&1, ^args.category in categories)
        )
        |> then(fn q ->
          if blank?(args[:tier]) do
            q
          else
            t = args.tier
            Ash.Query.filter(q, ^t in tiers or ^t in sizes)
          end
        end)
        |> then(fn q ->
          case args[:q] do
            q_text when is_binary(q_text) and q_text != "" ->
              Ash.Query.filter(q, contains(search_text, ^String.downcase(q_text)))

            _ ->
              q
          end
        end)
        |> Ash.Query.sort(kind: :asc, title: :asc)
        |> Ash.Query.select(@summary)
      end
    end

    read :listed_item do
      argument :item_id, :string, allow_nil?: false
      get? true
      filter expr(item_id == ^arg(:item_id) and listed == true)
    end

    read :for_item do
      argument :item_id, :string, allow_nil?: false
      filter expr(item_id == ^arg(:item_id))
      prepare build(sort: [not_before: :desc], select: @summary)
    end
  end

  def blank?(v), do: v in [nil, ""]

  attributes do
    uuid_primary_key :id
    attribute :item_id, :string, allow_nil?: false, public?: true
    attribute :version, :string, allow_nil?: false, public?: true
    attribute :digest, :string, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true
    attribute :publisher, :string, public?: true
    attribute :categories, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :keywords, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :provides, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :tiers, {:array, :string}, allow_nil?: false, default: [], public?: true

    # the tiers' sizes alone (large, medium, small), for the size filter
    attribute :sizes, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :count, :integer, allow_nil?: false, default: 1, public?: true
    attribute :logo, :string, public?: true

    attribute :bundle, :string,
      allow_nil?: false,
      description: "The signed item bundle file exactly as published."

    attribute :search_text, :string
    attribute :listed, :boolean, allow_nil?: false, default: false, public?: true
    attribute :signed_by, :string, allow_nil?: false, public?: true
    attribute :not_before, :utc_datetime, allow_nil?: false, public?: true
    attribute :expires, :utc_datetime, allow_nil?: false, public?: true
    attribute :first_sequence, :integer, allow_nil?: false, public?: true
    attribute :last_sequence, :integer, allow_nil?: false, public?: true
    attribute :commit, :string, public?: true
    create_timestamp :inserted_at, public?: true
  end

  identities do
    identity :digest, [:digest]
  end
end
