defmodule GroupStay.OperationsTest do
  use ExUnit.Case, async: true

  alias GroupStay.Operations

  describe "percentage/2" do
    test "rounds to the nearest cent" do
      assert Operations.percentage(10_002, 20) == 2_000
      assert Operations.percentage(10_003, 20) == 2_001
      assert Operations.percentage(10_004, 20) == 2_001
      assert Operations.percentage(45_000, 20) == 9_000
      assert Operations.percentage(52_500, 20) == 10_500
    end

    test "rounds an exact half-cent upward" do
      assert Operations.percentage(5, 10) == 1
      assert Operations.percentage(1, 50) == 1
      assert Operations.percentage(3, 50) == 2
    end

    test "handles zero amounts" do
      assert Operations.percentage(0, 20) == 0
    end
  end

  describe "canonical_json/1" do
    test "object key order is insignificant" do
      assert Operations.canonical_json(%{"b" => 1, "a" => 2}) ==
               Operations.canonical_json(%{"a" => 2, "b" => 1})
    end

    test "nested object key order is insignificant" do
      left = %{"outer" => %{"z" => [1, 2], "a" => %{"y" => true, "b" => nil}}, "k" => "v"}
      right = %{"k" => "v", "outer" => %{"a" => %{"b" => nil, "y" => true}, "z" => [1, 2]}}

      assert Operations.canonical_json(left) == Operations.canonical_json(right)
    end

    test "array order remains significant" do
      refute Operations.canonical_json([1, 2]) == Operations.canonical_json([2, 1])

      refute Operations.canonical_json(%{"rooms" => [%{"id" => "a"}, %{"id" => "b"}]}) ==
               Operations.canonical_json(%{"rooms" => [%{"id" => "b"}, %{"id" => "a"}]})
    end

    test "values remain significant" do
      refute Operations.canonical_json(%{"a" => 1}) == Operations.canonical_json(%{"a" => 2})
      refute Operations.canonical_json(%{"a" => 1}) == Operations.canonical_json(%{"a" => "1"})
      refute Operations.canonical_json(%{"a" => 1}) == Operations.canonical_json(%{"a" => 1.0})
      refute Operations.canonical_json(%{"a" => nil}) == Operations.canonical_json(%{})
    end

    test "encodes JSON scalars" do
      assert Operations.canonical_json(nil) == "null"
      assert Operations.canonical_json(true) == "true"
      assert Operations.canonical_json(false) == "false"
      assert Operations.canonical_json(42) == "42"
      assert Operations.canonical_json("hi") == "\"hi\""
      assert Operations.canonical_json([]) == "[]"
      assert Operations.canonical_json(%{}) == "{}"
    end
  end
end
