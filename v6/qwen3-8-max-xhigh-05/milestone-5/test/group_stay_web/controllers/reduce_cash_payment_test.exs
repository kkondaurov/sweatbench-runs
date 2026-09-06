defmodule GroupStayWeb.ReduceCashPaymentTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
  end

  defp reduce_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-10",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1000
      },
      overrides
    )
  end

  defp reduce(conn, overrides \\ %{}) do
    %{"results" => [result]} = submit_batch(conn, [reduce_op(overrides)])
    result
  end

  defp pay(conn, amount_cents, overrides \\ %{}) do
    pay_group(
      conn,
      "group-81",
      amount_cents,
      Map.merge(%{"operation_id" => "op-pay"}, overrides)
    )
  end

  defp room_by_id(data, room_id) do
    Enum.find(data["rooms"], &(&1["room_id"] == room_id))
  end

  describe "applying" do
    test "removes held cash in reverse fill order and reopens the deposit", %{conn: conn} do
      pay(conn, 10000)
      pay(conn, 5000, %{"operation_id" => "op-pay-2"})

      result = reduce(conn, %{"payment_operation_id" => "op-pay-2", "amount_cents" => 3000})

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay-2",
               "group_id" => "group-81",
               "amount_cents" => 3000,
               "outstanding_deposit_cents" => 7500,
               "revision" => 4
             }

      data = group_data(conn, "group-81")
      assert data["deposit_paid_cents"] == 12000
      assert data["cash_paid_cents"] == 12000
      assert room_by_id(data, "room-b")["cash_paid_cents"] == 3000

      ledger = ledger_data(conn)
      assert ledger["cash_held_cents"] == 12000
      assert ledger["cash_reduced_cents"] == 3000
    end

    test "walks the target payment's rooms in reverse fill order", %{conn: conn} do
      # op-pay fills room-a (9000) and room-b (1000).
      pay(conn, 10000)

      result = reduce(conn, %{"amount_cents" => 9500})

      assert result["status"] == "applied"

      data = group_data(conn, "group-81")
      # The last-filled room-b portion goes first, then room-a.
      assert room_by_id(data, "room-b")["cash_paid_cents"] == 0
      assert room_by_id(data, "room-a")["cash_paid_cents"] == 500
      assert data["outstanding_deposit_cents"] == 19000
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      pay(conn, 5000)

      first = reduce(conn, %{"amount_cents" => 2000})
      assert first["status"] == "applied"
      assert first["outstanding_deposit_cents"] == 16500

      second = reduce(conn, %{"operation_id" => "op-reduce-2", "amount_cents" => 2000})
      assert second["status"] == "applied"
      assert second["revision"] == 4

      assert ledger_data(conn)["cash_reduced_cents"] == 4000
      assert ledger_data(conn)["cash_held_cents"] == 1000
    end

    test "an amount equal to the complete remaining held portion is valid", %{conn: conn} do
      pay(conn, 5000)

      result = reduce(conn, %{"amount_cents" => 5000})

      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 19500

      ledger = ledger_data(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_reduced_cents"] == 5000

      assert group_data(conn, "group-81")["cash_paid_cents"] == 0
    end

    test "reductions of one payment leave other payments untouched", %{conn: conn} do
      pay(conn, 9000)
      pay(conn, 5000, %{"operation_id" => "op-pay-2"})

      reduce(conn, %{"payment_operation_id" => "op-pay-2", "amount_cents" => 5000})

      data = group_data(conn, "group-81")
      assert room_by_id(data, "room-a")["cash_paid_cents"] == 9000
      assert room_by_id(data, "room-b")["cash_paid_cents"] == 0
    end
  end

  describe "rejections" do
    test "rejects operation_not_found when no durable record exists", %{conn: conn} do
      result = reduce(conn, %{"payment_operation_id" => "op-missing"})

      assert result["status"] == "rejected"
      assert result["code"] == "operation_not_found"
      assert group_data(conn, "group-81")["revision"] == 1
    end

    test "legacy funding has no durable identity and is not found", %{conn: conn} do
      # Funding from before durable records has no payment identifier to
      # target, so any identifier naming it has no durable record.
      result = reduce(conn, %{"payment_operation_id" => "legacy-pay"})

      assert result["status"] == "rejected"
      assert result["code"] == "operation_not_found"
    end

    test "rejects payment_not_reducible for a non-payment operation", %{conn: conn} do
      result = reduce(conn, %{"payment_operation_id" => "op-1001"})

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_reducible"
    end

    test "rejects payment_not_reducible for a rejected payment", %{conn: conn} do
      pay(conn, 999_999)

      result = reduce(conn)

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_reducible"
    end

    test "rejects payment_not_reducible once no held cash remains", %{conn: conn} do
      pay(conn, 5000)
      reduce(conn, %{"amount_cents" => 5000})

      result = reduce(conn, %{"operation_id" => "op-reduce-2", "amount_cents" => 1})

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_reducible"
    end

    test "rejects payment_not_reducible when the group settled the payment", %{conn: conn} do
      pay(conn, 5000)
      cancel_group(conn, "group-81", "2026-11-26")

      result = reduce(conn)

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_reducible"
    end

    test "rejects invalid_amount for non-positive reductions", %{conn: conn} do
      pay(conn, 5000)

      ops =
        for {amount, index} <- Enum.with_index([0, -100, "1000", 10.5, true]) do
          reduce_op(%{"operation_id" => "op-reduce-#{index}", "amount_cents" => amount})
        end

      %{"results" => results} = submit_batch(conn, ops)

      assert Enum.all?(results, &(&1["status"] == "rejected"))
      assert Enum.all?(results, &(&1["code"] == "invalid_amount"))

      assert ledger_data(conn)["cash_reduced_cents"] == 0
    end

    test "rejects reduction_exceeds_held_cash when a smaller amount could succeed", %{
      conn: conn
    } do
      pay(conn, 5000)

      result = reduce(conn, %{"amount_cents" => 5001})

      assert result["status"] == "rejected"
      assert result["code"] == "reduction_exceeds_held_cash"

      assert ledger_data(conn)["cash_held_cents"] == 5000
      assert ledger_data(conn)["cash_reduced_cents"] == 0
      assert group_data(conn, "group-81")["revision"] == 2
    end

    test "rejects a stale revision before other domain rules", %{conn: conn} do
      pay(conn, 5000)

      result =
        reduce(conn, %{"amount_cents" => 0, "expected_revision" => 9})

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "group-81"
      assert result["expected_revision"] == 9
      assert result["actual_revision"] == 2
    end

    test "applies when the expected revision matches the payment's group", %{conn: conn} do
      pay(conn, 5000)

      result = reduce(conn, %{"expected_revision" => 2})

      assert result["status"] == "applied"
      assert result["revision"] == 3
    end
  end

  describe "durability" do
    test "retrying the original payment returns its exact original result", %{conn: conn} do
      pay(conn, 5000)
      reduce(conn, %{"amount_cents" => 2000})

      %{"results" => [retry]} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 5000
          }
        ])

      assert retry == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14500,
               "revision" => 2
             }

      # The retry does not reapply cash against the reopened deposit.
      assert group_data(conn, "group-81")["cash_paid_cents"] == 3000
      assert ledger_data(conn)["cash_held_cents"] == 3000
    end

    test "a reduction is durably idempotent itself", %{conn: conn} do
      pay(conn, 5000)

      %{"results" => [first]} = submit_batch(conn, [reduce_op(%{"amount_cents" => 2000})])
      %{"results" => [retry]} = submit_batch(conn, [reduce_op(%{"amount_cents" => 2000})])

      assert retry == first
      assert ledger_data(conn)["cash_reduced_cents"] == 2000
      assert group_data(conn, "group-81")["revision"] == 3
    end
  end
end
