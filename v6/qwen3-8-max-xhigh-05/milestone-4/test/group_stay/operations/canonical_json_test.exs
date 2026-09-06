defmodule GroupStay.Operations.CanonicalJsonTest do
  use ExUnit.Case, async: true

  alias GroupStay.Operations.CanonicalJson

  test "sorts object keys" do
    assert CanonicalJson.encode!(%{"b" => 1, "a" => 2}) == ~s({"a":2,"b":1})
  end

  test "preserves list order" do
    assert CanonicalJson.encode!([1, 2, 3]) == "[1,2,3]"
    assert CanonicalJson.encode!([2, 1]) == "[2,1]"
  end

  test "encodes nested structures with sorted keys at every level" do
    assert CanonicalJson.encode!(%{"x" => [%{"d" => true, "c" => nil}]}) ==
             ~s({"x":[{"c":null,"d":true}]})
  end

  test "encodes scalars" do
    assert CanonicalJson.encode!("text") == ~s("text")
    assert CanonicalJson.encode!(42) == "42"
    assert CanonicalJson.encode!(nil) == "null"
    assert CanonicalJson.encode!(true) == "true"
    assert CanonicalJson.encode!(false) == "false"
  end

  test "equivalent payloads with different key order encode identically" do
    left = Jason.decode!(~s({"a":{"x":1,"y":[1,2]},"b":"z"}))
    right = Jason.decode!(~s({"b":"z","a":{"y":[1,2],"x":1}}))

    assert CanonicalJson.encode!(left) == CanonicalJson.encode!(right)
  end

  test "different array order or values encode differently" do
    assert CanonicalJson.encode!([1, 2]) != CanonicalJson.encode!([2, 1])
    assert CanonicalJson.encode!(%{"a" => 1}) != CanonicalJson.encode!(%{"a" => 2})
  end
end
