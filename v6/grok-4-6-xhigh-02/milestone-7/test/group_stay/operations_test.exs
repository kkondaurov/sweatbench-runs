defmodule GroupStay.OperationsTest do
  use GroupStay.DataCase

  alias GroupStay.Operations
  alias GroupStay.Repo

  test "canonicalizes maps without regard to key order" do
    left = %{"type" => "open_group", "rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 1}]}
    right = %{rooms: [%{nightly_rate_cents: 1, room_id: "a"}], type: "open_group"}

    assert Operations.canonicalize(left) == Operations.canonicalize(right)
  end

  test "treats array order as significant" do
    first = Operations.canonicalize(%{"rooms" => [%{"room_id" => "a"}, %{"room_id" => "b"}]})
    second = Operations.canonicalize(%{"rooms" => [%{"room_id" => "b"}, %{"room_id" => "a"}]})

    refute first == second
  end

  test "an unexpected exception rolls back the claimed operation" do
    assert_raise RuntimeError, fn ->
      Repo.transaction(fn ->
        {:ok, _record} =
          Operations.claim("op-boom", "open_group", %{"operation_id" => "op-boom"})

        raise "boom"
      end)
    end

    assert Operations.get("op-boom") == nil
    assert Operations.get_result("op-boom") == nil
  end

  test "a handled result stays committed after the transaction succeeds" do
    Repo.transaction(fn ->
      {:ok, record} = Operations.claim("op-ok", "open_group", %{"operation_id" => "op-ok"})

      Operations.put_result!(record, %{
        operation_id: "op-ok",
        status: "rejected",
        code: "invalid_stay"
      })
    end)

    assert Operations.get_result("op-ok") == %{
             "operation_id" => "op-ok",
             "status" => "rejected",
             "code" => "invalid_stay"
           }
  end
end
