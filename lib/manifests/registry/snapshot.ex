defmodule Manifests.Registry.Snapshot do
  @moduledoc """
  A signed catalog index (`index` for published applications, `browse_index` for
  drafts), kept byte for byte so `/v1/index.json` serves exactly what was signed.
  """
  use Ash.Resource,
    otp_app: :manifests,
    domain: Manifests.Registry,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "catalog_snapshots"
    repo Manifests.Repo
  end

  actions do
    defaults [:read]

    create :record do
      upsert? true
      upsert_identity :sequence
      upsert_fields []
      accept [:kind, :sequence, :body, :entries, :expires, :commit]
    end

    read :latest do
      argument :kind, :string, allow_nil?: false
      filter expr(kind == ^arg(:kind))
      prepare build(sort: [sequence: :desc], limit: 1)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A(index|browse_index)\z/]

    attribute :sequence, :integer, allow_nil?: false, public?: true
    attribute :body, :string, allow_nil?: false
    attribute :entries, :integer, allow_nil?: false, public?: true
    attribute :expires, :utc_datetime, allow_nil?: false, public?: true
    attribute :commit, :string, public?: true
    create_timestamp :inserted_at, public?: true
  end

  identities do
    identity :sequence, [:kind, :sequence]
  end
end
