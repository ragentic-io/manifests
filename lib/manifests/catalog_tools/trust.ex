defmodule Manifests.CatalogTools.Trust do
  @moduledoc """
  Ed25519 envelopes for the catalog's signed objects, in the scheme
  `RagenticManifests.Trust` verifies: the signature covers
  `"ragentic.manifests/v1\\n" <> payload_bytes`, both payload and signature are
  base64url without padding, the payload is canonical JSON and a bundle's file name
  is the SHA-256 of its payload bytes.

  The signing key is a 32-byte Ed25519 seed, read only from the
  `MANIFESTS_SIGNING_KEY` environment variable (hex or base64url), exactly like
  `tools/catalog.py`. It is never written anywhere.
  """

  alias Manifests.CatalogTools.{Error, Json}

  @prefix "ragentic.manifests/v1\n"

  def prefix, do: @prefix

  @doc "base64url without padding."
  def b64e(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc """
  `base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))`: accepts both alphabets and
  ignores padding and other characters outside them. Raises `Error` (Python's
  `binascii.Error`, a `ValueError`) when the data can't be decoded.
  """
  def b64d(s) when is_binary(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, bytes} -> bytes
      :error -> lenient_b64d(s)
    end
  end

  def b64d(other), do: raise(ArgumentError, "expected a base64 string, got: #{inspect(other)}")

  defp lenient_b64d(s) do
    unless ascii?(s), do: raise(Error, "string argument should contain only ASCII characters")

    data =
      for <<c <- s>>, c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in ~c"-_+/", into: "" do
        case c do
          ?+ -> "-"
          ?/ -> "_"
          c -> <<c>>
        end
      end

    case Base.url_decode64(data, padding: false) do
      {:ok, bytes} -> bytes
      :error -> raise Error, "Invalid base64-encoded string"
    end
  end

  defp ascii?(s), do: for(<<c <- s>>, c > 127, reduce: true, do: (_ -> false))

  @doc "SHA-256 as lowercase hex."
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "The raw public key of a 32-byte seed."
  def public_key(seed) when byte_size(seed) == 32 do
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
    public
  end

  @doc "Sign the canonical JSON of `payload`: `{payload_bytes, envelope}`."
  def seal(payload, seed) do
    data = Json.canonical(payload)
    signature = :crypto.sign(:eddsa, :none, @prefix <> data, [seed, :ed25519])
    {data, %{"payload" => b64e(data), "signature" => b64e(signature)}}
  end

  @doc """
  The payload bytes of an envelope signed by `public`, or `{:error, reason}` where
  the Python tool raised `ValueError` (bad signature or bad base64). A missing
  `payload`/`signature` key raises, as `KeyError` did.
  """
  def open_envelope(env, public) do
    payload = Json.fetch!(env, "payload")

    try do
      data = b64d(payload)
      signature = b64d(Json.fetch!(env, "signature"))

      if verify?(data, signature, public), do: {:ok, data}, else: {:error, "bad signature"}
    rescue
      e in Error -> {:error, e.message}
    end
  end

  defp verify?(data, signature, public) do
    byte_size(signature) == 64 and
      :crypto.verify(:eddsa, :none, @prefix <> data, signature, [public, :ed25519])
  rescue
    _ -> false
  end

  @doc """
  The signing seed from `MANIFESTS_SIGNING_KEY`, checked against the pinned root
  (base64url) of `registry.json`. Raises `Error` with the Python tool's messages.
  """
  def signing_key!(root) do
    raw = System.get_env("MANIFESTS_SIGNING_KEY", "") |> Manifests.CatalogTools.Py.strip()
    if raw == "", do: raise(Error, "MANIFESTS_SIGNING_KEY is not set")

    seed =
      if raw =~ ~r/\A[0-9a-fA-F]{64}\z/,
        do: Base.decode16!(raw, case: :mixed),
        else: b64d(raw)

    if byte_size(seed) != 32,
      do: raise(Error, "MANIFESTS_SIGNING_KEY must be a 32-byte Ed25519 seed (hex or base64url)")

    if b64e(public_key(seed)) != root,
      do: raise(Error, "MANIFESTS_SIGNING_KEY does not match the pinned root in registry.json")

    seed
  end
end
