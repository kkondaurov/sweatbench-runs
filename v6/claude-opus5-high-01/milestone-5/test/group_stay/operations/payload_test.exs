defmodule GroupStay.Operations.PayloadTest do
  use ExUnit.Case, async: true

  alias GroupStay.Operations.Payload

  describe "canonical/1" do
    test "orders object keys and leaves arrays alone" do
      assert ~s({"a":1,"b":[3,2,1],"c":{"x":null,"y":"z"}}) ==
               Payload.canonical(%{"c" => %{"y" => "z", "x" => nil}, "b" => [3, 2, 1], "a" => 1})
    end

    test "is the same text however the keys are ordered" do
      keys = for index <- 1..64, do: {"key-#{index}", index}

      assert Payload.canonical(Map.new(keys)) == Payload.canonical(Map.new(Enum.reverse(keys)))
    end

    test "atom and string keys canonicalise the same way" do
      assert Payload.canonical(%{status: "applied", revision: 2}) ==
               Payload.canonical(%{"revision" => 2, "status" => "applied"})
    end

    test "distinguishes array order, values, and JSON types" do
      refute Payload.canonical(%{"rooms" => ["a", "b"]}) ==
               Payload.canonical(%{"rooms" => ["b", "a"]})

      refute Payload.canonical(%{"amount_cents" => 100}) ==
               Payload.canonical(%{"amount_cents" => 100.0})

      refute Payload.canonical(%{"amount_cents" => 100}) ==
               Payload.canonical(%{"amount_cents" => "100"})

      refute Payload.canonical(%{"a" => 1}) == Payload.canonical(%{"a" => 1, "b" => nil})
    end

    test "escapes strings as JSON" do
      assert ~s({"note":"a \\"quoted\\" line\\n"}) ==
               Payload.canonical(%{"note" => ~s(a "quoted" line\n)})
    end
  end
end
