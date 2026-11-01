defmodule Manifests.Analytics.DownloadDay do
  @moduledoc """
  How many times one signed bundle was served on one UTC day. Incremented by
  `Manifests.Analytics.record/2`; weeks and years are rolled up from these rows.
  """
  use Ash.Resource,
    otp_app: :manifests,
    domain: Manifests.Analytics,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "manifest_downloads"
    repo Manifests.Repo

    custom_indexes do
      index [:manifest_id, :day]
    end
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
    attribute :manifest_id, :string, allow_nil?: false, public?: true
    attribute :digest, :string, allow_nil?: false, public?: true
    attribute :day, :date, allow_nil?: false, public?: true
    attribute :count, :integer, allow_nil?: false, default: 0, public?: true
  end

  identities do
    identity :digest_day, [:digest, :day]
  end
end
