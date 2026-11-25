defmodule ExGAM.CanonicalProfileTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExGAM.Canonical.{Codec, Value}
  alias ExGAM.Seal

  property "the general and budgeted profiles produce the same portable bytes and digest" do
    check all(fields <- map_of(binary(max_length: 12), list_of(integer(), max_length: 4))) do
      bytes = Codec.encode!(fields)
      assert {:ok, ^bytes} = Value.encode(fields)
      assert {:ok, ^fields} = Codec.decode(bytes)
      assert :ok = Codec.validate(fields)
      assert Codec.digest!(fields) == Value.digest!(fields)
      assert Codec.digest!(fields) == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    end
  end

  test "typed records require the exact declared fields and an explicit allowlist" do
    value = %URI{path: "/a"}
    opts = [allowed_structs: [URI]]
    bytes = Codec.encode!(value, opts)
    assert {:ok, ^value} = Codec.decode(bytes, opts)
    assert {:error, {:disallowed_canonical_struct, [], _}} = Codec.decode(bytes)
    assert {:error, {:invalid_allowed_structs, _}} = Codec.encode(value, allowed_structs: [nil])

    assert {:error, {:canonical_value_too_large, _, 8}} =
             Codec.encode(value, opts ++ [max_bytes: 8])

    assert_raise ArgumentError, fn -> Codec.encode!(value) end
    assert_raise ArgumentError, fn -> Codec.digest!(value) end
  end

  test "runtime seals bind the material, domain and secret" do
    secret = Seal.generate_secret()
    material = %{revision: 3}
    assert {:ok, seal} = Seal.sign(material, secret, "grant")
    assert :ok = Seal.verify(material, seal, secret, "grant")
    assert :error = Seal.verify(material, seal, secret, "context")
    assert :error = Seal.verify(material, seal, Seal.generate_secret(), "grant")
    assert :error = Seal.verify(%{revision: 4}, seal, secret, "grant")
    assert :error = Seal.verify(material, nil, secret, "grant")
    assert {:error, :invalid_seal_material} = Seal.sign(material, <<0>>, "grant")
  end
end
