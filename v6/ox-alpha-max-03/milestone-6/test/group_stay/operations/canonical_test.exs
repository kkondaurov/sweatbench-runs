defmodule GroupStay.Operations.CanonicalTest do
  use ExUnit.Case, async: true

  alias GroupStay.Operations.Canonical

  describe "json/1" do
    test "object key order is irrelevant, including nested objects" do
      left = %{
        "type" => "open_group",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 100},
          %{"nightly_rate_cents" => 200, "room_id" => "room-b"}
        ],
        "expected_revision" => 2
      }

      right = %{
        "expected_revision" => 2,
        "rooms" => [
          %{"nightly_rate_cents" => 100, "room_id" => "room-a"},
          %{"room_id" => "room-b", "nightly_rate_cents" => 200}
        ],
        "type" => "open_group"
      }

      assert Canonical.json(left) == Canonical.json(right)
    end

    test "array order and values remain significant" do
      rooms = [%{"room_id" => "a"}, %{"room_id" => "b"}]

      refute Canonical.json(%{"rooms" => rooms}) ==
               Canonical.json(%{"rooms" => Enum.reverse(rooms)})

      refute Canonical.json(%{"amount_cents" => 100}) == Canonical.json(%{"amount_cents" => 101})
    end

    test "atom keys and string keys are equivalent" do
      assert Canonical.json(%{operation_id: "op", type: :cancel_group}) ==
               Canonical.json(%{"operation_id" => "op", "type" => "cancel_group"})
    end

    test "distinguishes integers from floats and preserves nulls and booleans" do
      refute Canonical.json(%{"v" => 1}) == Canonical.json(%{"v" => 1.0})
      assert Canonical.json(%{"v" => nil, "w" => true}) == ~s({"v":null,"w":true})
    end

    test "handles non-map payloads" do
      assert Canonical.json([]) == "[]"
      assert Canonical.json("op") == ~s("op")
    end
  end
end
