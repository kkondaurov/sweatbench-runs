defmodule GroupStay.CanonicalJsonTest do
  use ExUnit.Case, async: true

  alias GroupStay.CanonicalJson

  test "object key order is irrelevant at every level and array order is not" do
    left = %{
      "b" => 1,
      "a" => [%{"z" => 1, "y" => [3, 2]}, %{"m" => nil}]
    }

    right = %{
      "a" => [%{"y" => [3, 2], "z" => 1}, %{"m" => nil}],
      "b" => 1
    }

    assert CanonicalJson.encode(left) == CanonicalJson.encode(right)

    swapped = %{
      "a" => [%{"m" => nil}, %{"y" => [3, 2], "z" => 1}],
      "b" => 1
    }

    refute CanonicalJson.encode(left) == CanonicalJson.encode(swapped)
  end

  test "missing keys, nulls, and numeric types stay distinct" do
    omitted = %{"amount_cents" => 1}
    nulled = %{"amount_cents" => 1, "expected_revision" => nil}
    float = %{"amount_cents" => 1.0}

    refute CanonicalJson.encode(omitted) == CanonicalJson.encode(nulled)
    refute CanonicalJson.encode(omitted) == CanonicalJson.encode(float)
  end
end
