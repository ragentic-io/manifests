defmodule Manifests.Registry.Version do
  @moduledoc """
  One signed bundle of an application. The bundle file is kept byte for byte, so
  clients can re-verify it themselves; its digest is the SHA-256 of the payload.

  A version string can be signed more than once (each re-signing moves its
  validity window), so `(manifest_id, version)` is not unique: the newest signing
  of a version is the one a `?version=` link resolves to.
  """
  use Ash.Resource,
    otp_app: :manifests,
    domain: Manifests.Registry,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "manifest_versions"
    repo Manifests.Repo

    references do
      reference :manifest, on_delete: :delete
    end

    custom_indexes do
      index [:manifest_id, :version]
    end
  end

  actions do
    defaults [:read]

    create :record do
      upsert? true
      upsert_identity :digest
      # The bundle never changes for a digest; only how widely it was published can.
      upsert_fields [:catalog, :last_sequence]

      accept [
        :manifest_id,
        :version,
        :digest,
        :catalog,
        :protocol,
        :title,
        :readiness,
        :endpoint,
        :credential,
        :bundle,
        :operations,
        :signed_by,
        :not_before,
        :expires,
        :first_sequence,
        :last_sequence,
        :commit
      ]
    end

    update :seen do
      accept [:catalog, :last_sequence]
    end

    read :for_manifest do
      argument :manifest_id, :string, allow_nil?: false
      filter expr(manifest_id == ^arg(:manifest_id))

      prepare build(
                sort: [not_before: :desc],
                select: [
                  :id,
                  :manifest_id,
                  :version,
                  :digest,
                  :catalog,
                  :protocol,
                  :title,
                  :readiness,
                  :endpoint,
                  :credential,
                  :signed_by,
                  :not_before,
                  :expires,
                  :first_sequence,
                  :last_sequence,
                  :commit,
                  :inserted_at
                ]
              )
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :manifest_id, :string, allow_nil?: false, public?: true
    attribute :version, :string, allow_nil?: false, public?: true
    attribute :digest, :string, allow_nil?: false, public?: true
    attribute :catalog, :string, allow_nil?: false, public?: true
    attribute :protocol, :string, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :readiness, :string, public?: true
    attribute :endpoint, :string, public?: true

    attribute :credential, :string,
      public?: true,
      description: "The setup credential type, e.g. static_bearer."

    attribute :bundle, :string,
      allow_nil?: false,
      description: "The signed bundle file exactly as published."

    attribute :operations, {:array, :map},
      allow_nil?: false,
      default: [],
      public?: true,
      description:
        "Compact operation list for display and search; the full graph is in the bundle."

    attribute :signed_by, :string,
      allow_nil?: false,
      public?: true,
      description: "SHA-256 key id of the root that signed it."

    attribute :not_before, :utc_datetime, allow_nil?: false, public?: true
    attribute :expires, :utc_datetime, allow_nil?: false, public?: true
    attribute :first_sequence, :integer, allow_nil?: false, public?: true
    attribute :last_sequence, :integer, allow_nil?: false, public?: true
    attribute :commit, :string, public?: true
    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :manifest, Manifests.Registry.Manifest do
      source_attribute :manifest_id
      attribute_type :string
      allow_nil? false
      attribute_writable? true
      define_attribute? false
    end
  end

  identities do
    identity :digest, [:digest]
  end
end
