defmodule Manifests.Trust do
  @moduledoc """
  Ed25519 envelopes over exact JSON bytes, with domain-separated signatures.
  Roots are supplied out of band by the caller; an envelope never establishes trust.
  Delegations narrow exact application scopes and expiration and have bounded depth.
  """
  @prefix "ragentic.manifests/v1\n"
  @max_payload_bytes 16_777_216
  @max_encoded_bytes div(@max_payload_bytes * 4 + 2, 3)

  def keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  def key_id(public), do: :crypto.hash(:sha256, public) |> Base.encode16(case: :lower)

  def sign(payload, private) when is_map(payload) do
    bytes = Jason.encode!(payload)

    %{
      "payload" => Base.url_encode64(bytes, padding: false),
      "signature" =>
        Base.url_encode64(:crypto.sign(:eddsa, :none, @prefix <> bytes, [private, :ed25519]),
          padding: false
        )
    }
  end

  def delegate(public, apps, not_before, expires, private) do
    sign(
      %{
        "kind" => "authority",
        "public_key" => Base.url_encode64(public, padding: false),
        "apps" => apps,
        "not_before" => not_before,
        "expires" => expires
      },
      private
    )
  end

  @doc "Verify against a pinned root and exact expected identity, version and SHA-256."
  def verify(bundle, root, expected, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    revoked = Keyword.get(opts, :revoked, [])

    with true <- is_binary(root) and byte_size(root) == 32,
         false <- key_id(root) in revoked,
         %{"chain" => chain, "envelope" => envelope} <- bundle,
         true <- is_list(chain) and length(chain) <= 8,
         {:ok, authority} <-
           chain(
             chain,
             %{key: root, apps: :all, expires: 9_223_372_036_854_775_807, not_before: 0},
             now,
             revoked
           ),
         {:ok, payload} <- open(envelope, authority.key),
         %{
           "kind" => "bundle",
           "app" => app,
           "version" => version,
           "expires" => expires,
           "not_before" => starts
         } <- payload,
         true <- valid_time?(starts, expires, now),
         true <- starts >= authority.not_before and expires <= authority.expires,
         true <- allowed?(authority.apps, app),
         true <- app == expected.app and version == expected.version,
         {:ok, bytes} <- Base.url_decode64(envelope["payload"], padding: false),
         true <- key_id(bytes) == expected.digest do
      {:ok, payload}
    else
      _ -> {:error, :untrusted_bundle}
    end
  rescue
    _ -> {:error, :untrusted_bundle}
  end

  @doc "Verify a root-signed catalog index with an independently pinned registry identity."
  def verify_index(envelope, root, registry, minimum_sequence, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    revoked = Keyword.get(opts, :revoked, [])
    kind = Keyword.get(opts, :catalog_kind, "index")

    with true <- kind in ["index", "browse_index"],
         true <- is_binary(root) and byte_size(root) == 32,
         false <- key_id(root) in revoked,
         true <- is_integer(minimum_sequence) and minimum_sequence >= 0,
         {:ok,
          %{
            "kind" => ^kind,
            "registry" => ^registry,
            "sequence" => sequence,
            "not_before" => starts,
            "expires" => expires,
            "entries" => entries
          } = payload} <- open(envelope, root),
         true <- is_integer(sequence) and sequence >= minimum_sequence,
         true <- valid_time?(starts, expires, now),
         true <- is_list(entries) and length(entries) <= 10_000,
         true <- Enum.all?(entries, &valid_entry?/1),
         ids = Enum.map(entries, & &1["id"]),
         true <- length(ids) == length(Enum.uniq(ids)) do
      {:ok, payload}
    else
      _ -> {:error, :untrusted_index}
    end
  rescue
    _ -> {:error, :untrusted_index}
  end

  defp valid_entry?(%{
         "id" => id,
         "version" => version,
         "digest" => digest,
         "title" => title,
         "protocol" => protocol
       }) do
    is_binary(id) and Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,127}\z/, id) and
      is_binary(version) and byte_size(version) in 1..128 and
      is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) and
      is_binary(title) and byte_size(title) in 1..256 and
      protocol in ~w(openapi graphql asyncapi)
  end

  defp valid_entry?(_), do: false

  def digest(%{"payload" => encoded}) do
    encoded |> Base.url_decode64!(padding: false) |> key_id()
  end

  defp chain([], parent, _, _), do: {:ok, parent}

  defp chain([cert | rest], parent, now, revoked) do
    with {:ok,
          %{
            "kind" => "authority",
            "public_key" => encoded,
            "apps" => apps,
            "not_before" => starts,
            "expires" => expires
          }} <- open(cert, parent.key),
         true <- is_list(apps) and apps != [] and Enum.all?(apps, &is_binary/1),
         true <- Enum.all?(apps, &allowed?(parent.apps, &1)),
         true <- valid_time?(starts, expires, now),
         true <- starts >= parent.not_before and expires <= parent.expires,
         {:ok, key} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(key) == 32,
         false <- key_id(key) in revoked do
      chain(rest, %{key: key, apps: apps, expires: expires, not_before: starts}, now, revoked)
    else
      _ -> {:error, :invalid_authority}
    end
  end

  defp open(%{"payload" => encoded, "signature" => sig}, public)
       when is_binary(encoded) and byte_size(encoded) <= @max_encoded_bytes and is_binary(sig) and
              byte_size(sig) <= 128 do
    with {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(bytes) <= @max_payload_bytes,
         {:ok, signature} <- Base.url_decode64(sig, padding: false),
         true <- :crypto.verify(:eddsa, :none, @prefix <> bytes, signature, [public, :ed25519]),
         {:ok, payload} when is_map(payload) <- Jason.decode(bytes) do
      {:ok, payload}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp open(_, _), do: {:error, :invalid_envelope}
  defp allowed?(:all, app), do: is_binary(app)
  defp allowed?(apps, app), do: app in apps

  defp valid_time?(starts, expires, now),
    do: is_integer(starts) and is_integer(expires) and starts <= now and now < expires
end
