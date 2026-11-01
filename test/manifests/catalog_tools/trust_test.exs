defmodule Manifests.CatalogTools.TrustTest do
  use ExUnit.Case, async: true

  alias Manifests.CatalogTools.{Json, Trust}

  @seed :crypto.hash(:sha256, "catalog tools test key")

  test "seal/2 signs the canonical payload with the ragentic.manifests/v1 prefix" do
    payload = %{
      "kind" => "bundle",
      "app" => "acme",
      "version" => "1",
      "not_before" => 1,
      "expires" => 2
    }

    {data, env} = Trust.seal(payload, @seed)

    assert data == Json.canonical(payload)
    refute env["payload"] =~ "="
    refute env["signature"] =~ "="
    assert Base.url_decode64!(env["payload"], padding: false) == data

    public = Trust.public_key(@seed)
    signature = Base.url_decode64!(env["signature"], padding: false)

    assert :crypto.verify(:eddsa, :none, "ragentic.manifests/v1\n" <> data, signature, [
             public,
             :ed25519
           ])

    refute :crypto.verify(:eddsa, :none, data, signature, [public, :ed25519])
  end

  test "open_envelope/2 round-trips and rejects tampering or another key" do
    {data, env} = Trust.seal(%{"a" => [1, 2.5, "é"]}, @seed)
    public = Trust.public_key(@seed)

    assert Trust.open_envelope(env, public) == {:ok, data}

    tampered = %{env | "payload" => Trust.b64e(~s({"a":[1,2.5,"e"]}))}
    assert {:error, _} = Trust.open_envelope(tampered, public)

    other = Trust.public_key(:crypto.hash(:sha256, "another key"))
    assert {:error, _} = Trust.open_envelope(env, other)
    assert {:error, _} = Trust.open_envelope(%{env | "signature" => "AAAA"}, public)
  end

  test "signing is deterministic, and a bundle is named by the SHA-256 of its payload bytes" do
    payload = %{"app" => "acme", "kind" => "bundle"}
    {data, env} = Trust.seal(payload, @seed)
    assert {^data, ^env} = Trust.seal(payload, @seed)

    assert Trust.sha256(data) == :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    assert Json.compact(%{"chain" => [], "envelope" => env}) =~
             ~r/\A\{"chain":\[\],"envelope":\{"payload":"[^"]+","signature":"[^"]+"\}\}\z/
  end

  test "b64d/1 accepts what Python's urlsafe_b64decode accepts" do
    assert Trust.b64d("aGk") == "hi"
    assert Trust.b64d("aGk=") == "hi"
    assert Trust.b64d("-_8") == <<251, 255>>
    assert Trust.b64d("+/8") == <<251, 255>>
  end
end
