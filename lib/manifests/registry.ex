defmodule Manifests.Registry do
  @moduledoc """
  The manifest registry: every application, every signed version of it, and the
  signed catalog indexes that published them.

  Rows are only ever written by `Manifests.Catalog.Import` after the signatures
  check out, so anything read from here has been verified against a pinned root.
  """
  use Ash.Domain, otp_app: :manifests, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Manifests.Registry.Manifest do
      define :get_manifest, action: :read, get_by: [:id]
      define :search_manifests, action: :search, args: [:filters]
    end

    resource Manifests.Registry.Version do
      define :versions_of, action: :for_manifest, args: [:manifest_id]
      define :version_by_digest, action: :read, get_by: [:digest]
    end

    resource Manifests.Registry.Item do
      define :search_items, action: :search, args: [:q, :kind, :category, :publisher, :tier]
      define :listed_item, action: :listed_item, args: [:item_id]
      define :item_versions, action: :for_item, args: [:item_id]
      define :item_by_digest, action: :read, get_by: [:digest]
    end

    resource Manifests.Registry.Snapshot do
      define :latest_snapshot, action: :latest, args: [:kind], get?: true
    end
  end
end
