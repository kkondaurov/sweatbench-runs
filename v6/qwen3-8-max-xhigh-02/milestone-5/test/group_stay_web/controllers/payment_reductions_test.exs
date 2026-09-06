defmodule GroupStayWeb.PaymentReductionsTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp results(conn), do: json_response(conn, 200)["results"]

  defp single_result(conn, operations) do
    [result] = conn |> submit(operations) |> results()
    result
  end

  # Two rooms for three nights: room-a deposit 9000, room-b deposit 10500.
  # Flex-14 refundable through 2026-11-26.
  defp open_group(conn, overrides \\ %{}) do
    op =
      Map.merge(
        %{
          "operation_id" => "op-open",
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => "group-81",
          "guest_id" => "guest-22",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => "flexible",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        },
        overrides
      )

    result = single_result(conn, [op])
    assert result["status"] == "applied"
    result
  end

  defp pay(conn, overrides \\ %{}) do
    op =
      Map.merge(
        %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 5000
        },
        overrides
      )

    result = single_result(conn, [op])
    assert result["status"] == "applied"
    result
  end

  defp reduce_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1500
      },
      overrides
    )
  end

  defp reduce(conn, overrides \\ %{}) do
    result = single_result(conn, [reduce_op(overrides)])
    assert result["status"] == "applied"
    result
  end

  defp cancel_group(conn, overrides \\ %{}) do
    op =
      Map.merge(
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81"
        },
        overrides
      )

    result = single_result(conn, [op])
    assert result["status"] == "applied"
    result
  end

  defp cancel_rooms(conn, overrides) do
    op =
      Map.merge(
        %{
          "operation_id" => "op-cancel-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81",
          "room_ids" => ["room-b"]
        },
        overrides
      )

    result = single_result(conn, [op])
    assert result["status"] == "applied"
    result
  end

  defp get_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_payment(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp room_by_id(group, room_id) do
    Enum.find(group["rooms"], &(&1["room_id"] == room_id))
  end

  describe "reduce_cash_payment" do
    test "removes held cash from the target payment and reopens the deposit", %{conn: conn} do
      open_group(conn)
      pay(conn)

      result = reduce(conn)

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 1500,
               "outstanding_deposit_cents" => 16000,
               "revision" => 3
             }

      group = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 3500
      assert group["outstanding_deposit_cents"] == 16000
      assert room_by_id(group, "room-a")["cash_paid_cents"] == 3500

      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 3500
      assert ledger["cash_reduced_cents"] == 1500

      assert get_payment(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 5000,
               "held_cents" => 3500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1500,
               "charged_back_cents" => 0
             }
    end

    test "removes held allocations in reverse fill order", %{conn: conn} do
      open_group(conn)
      pay(conn, %{"operation_id" => "op-pay-1", "amount_cents" => 5000})
      pay(conn, %{"operation_id" => "op-pay-2", "amount_cents" => 6000})

      # op-pay-2 filled room-a's remaining 4000 and then room-b's 2000.
      # Reducing it by 3000 releases room-b first, then room-a.
      result = reduce(conn, %{"payment_operation_id" => "op-pay-2", "amount_cents" => 3000})
      assert result["outstanding_deposit_cents"] == 11500

      group = get_group(conn, "group-81")
      assert room_by_id(group, "room-a")["cash_paid_cents"] == 8000
      assert room_by_id(group, "room-b")["cash_paid_cents"] == 0

      # The earlier payment's allocations are untouched.
      assert get_payment(conn, "op-pay-1")["held_cents"] == 5000
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      open_group(conn)
      pay(conn)

      assert reduce(conn, %{"amount_cents" => 1000})["outstanding_deposit_cents"] == 15500

      assert reduce(conn, %{
               "operation_id" => "op-reduce-2",
               "amount_cents" => 1500
             })["outstanding_deposit_cents"] == 17000

      # An amount equal to the complete remaining held portion is valid.
      result = reduce(conn, %{"operation_id" => "op-reduce-3", "amount_cents" => 2500})
      assert result["outstanding_deposit_cents"] == 19500

      group = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 0
      assert room_by_id(group, "room-a")["cash_paid_cents"] == 0

      # Nothing held remains, so the target can never accept a reduction.
      result =
        single_result(conn, [reduce_op(%{"operation_id" => "op-reduce-4", "amount_cents" => 1})])

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_reducible"

      assert get_payment(conn, "op-pay")["reduced_cents"] == 5000
    end

    test "rejects a reduction exceeding the held cash", %{conn: conn} do
      open_group(conn)
      pay(conn)

      result = single_result(conn, [reduce_op(%{"amount_cents" => 5001})])

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "rejected",
               "code" => "reduction_exceeds_held_cash"
             }

      # The rejection left everything unchanged.
      assert get_group(conn, "group-81")["revision"] == 2
      assert get_payment(conn, "op-pay")["held_cents"] == 5000
      assert get_ledger(conn)["cash_reduced_cents"] == 0
    end

    test "reduces only cash still held on active rooms", %{conn: conn} do
      open_group(conn)
      pay(conn, %{"amount_cents" => 13000})

      # room-b's 4000 is retained; only the 9000 on room-a stays held.
      assert cancel_rooms(conn, %{
               "room_ids" => ["room-b"],
               "occurred_on" => "2026-11-27"
             })["retained_cents"] == 4000

      assert get_payment(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 13000,
               "held_cents" => 9000,
               "refunded_cents" => 0,
               "retained_cents" => 4000,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      result = single_result(conn, [reduce_op(%{"amount_cents" => 9001})])
      assert result["status"] == "rejected"
      assert result["code"] == "reduction_exceeds_held_cash"

      result = reduce(conn, %{"operation_id" => "op-reduce-held", "amount_cents" => 9000})
      assert result["outstanding_deposit_cents"] == 9000

      assert get_payment(conn, "op-pay")["held_cents"] == 0
      assert get_payment(conn, "op-pay")["reduced_cents"] == 9000
    end

    test "rejects a reduction once the group is fully cancelled", %{conn: conn} do
      open_group(conn)
      pay(conn)
      cancel_group(conn)

      result = single_result(conn, [reduce_op()])
      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_reducible"
    end

    test "rejects targets that can never be reduced", %{conn: conn} do
      open_group(conn)

      # No durable record exists under the identifier.
      result = single_result(conn, [reduce_op(%{"payment_operation_id" => "op-nobody"})])
      assert result["status"] == "rejected"
      assert result["code"] == "operation_not_found"

      # A record that is not a payment operation.
      result =
        single_result(conn, [
          reduce_op(%{"operation_id" => "op-reduce-open", "payment_operation_id" => "op-open"})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_reducible"

      # A rejected payment.
      assert single_result(conn, [
               %{
                 "operation_id" => "op-pay-bad",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 0
               }
             ])["code"] == "invalid_amount"

      result =
        single_result(conn, [
          reduce_op(%{"operation_id" => "op-reduce-bad", "payment_operation_id" => "op-pay-bad"})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "payment_not_reducible"

      # Legacy funding has no durable operation identity.
      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "rejects unusable amounts without changing state", %{conn: conn} do
      open_group(conn)
      pay(conn)

      for {amount, index} <- Enum.with_index([0, -500, "1500", 10.5]) do
        result =
          single_result(conn, [
            reduce_op(%{"operation_id" => "op-reduce-#{index}", "amount_cents" => amount})
          ])

        assert result["status"] == "rejected", "expected rejection for #{inspect(amount)}"
        assert result["code"] == "invalid_amount", "unexpected code for #{inspect(amount)}"
      end

      for {op, index} <-
            Enum.with_index([
              Map.delete(reduce_op(), "amount_cents"),
              Map.delete(reduce_op(), "payment_operation_id")
            ]) do
        op = Map.put(op, "operation_id", "op-missing-#{index}")
        [result] = results(submit(conn, [op]))
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end

      assert get_group(conn, "group-81")["revision"] == 2
      assert get_payment(conn, "op-pay")["held_cents"] == 5000
    end

    test "follows the revision contract for the original payment's group", %{conn: conn} do
      open_group(conn)
      pay(conn)

      result = reduce(conn, %{"expected_revision" => 2})
      assert result["revision"] == 3

      result =
        single_result(conn, [
          reduce_op(%{"operation_id" => "op-reduce-stale", "expected_revision" => 2})
        ])

      assert result == %{
               "operation_id" => "op-reduce-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 3
             }

      # A stale revision is rejected before the reduction domain rules.
      result =
        single_result(conn, [
          reduce_op(%{
            "operation_id" => "op-reduce-stale-2",
            "amount_cents" => 99999,
            "expected_revision" => 99
          })
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "stale_revision"
      assert get_group(conn, "group-81")["revision"] == 3
    end

    test "is durably idempotent", %{conn: conn} do
      open_group(conn)
      pay(conn)

      first = reduce(conn)
      retry = single_result(conn, [reduce_op()])
      assert retry == first

      # The retry did not reduce again.
      assert get_payment(conn, "op-pay")["held_cents"] == 3500
      assert get_group(conn, "group-81")["revision"] == 3

      # A remembered rejection replays even once the amount would fit.
      rejected =
        single_result(conn, [
          reduce_op(%{"operation_id" => "op-reduce-big", "amount_cents" => 9999})
        ])

      assert rejected["code"] == "reduction_exceeds_held_cash"

      assert single_result(conn, [
               reduce_op(%{"operation_id" => "op-reduce-big", "amount_cents" => 9999})
             ]) == rejected

      # A reused identifier with a different payload conflicts.
      conflict = single_result(conn, [reduce_op(%{"amount_cents" => 100})])
      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"
    end

    test "retrying the original payment returns its exact original result", %{conn: conn} do
      open_group(conn)
      original = pay(conn)
      reduce(conn)

      # The stored result is returned verbatim and cash is not reapplied,
      # even though the group state now differs.
      assert single_result(conn, [
               %{
                 "operation_id" => "op-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 5000
               }
             ]) == original

      assert get_payment(conn, "op-pay")["recorded_cents"] == 5000
      assert get_payment(conn, "op-pay")["reduced_cents"] == 1500
      assert get_group(conn, "group-81")["deposit_paid_cents"] == 3500
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reports every disposition, always present and summing to recorded", %{conn: conn} do
      open_group(conn)
      pay(conn, %{"amount_cents" => 13000})

      # Settle part, reduce part, then charge back the rest.
      cancel_rooms(conn, %{"room_ids" => ["room-b"], "occurred_on" => "2026-11-27"})
      reduce(conn, %{"amount_cents" => 1000})

      statement = get_payment(conn, "op-pay")

      assert statement == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 13000,
               "held_cents" => 8000,
               "refunded_cents" => 0,
               "retained_cents" => 4000,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1000,
               "charged_back_cents" => 0
             }

      dispositions =
        for key <-
              ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents) do
          statement[key]
        end

      assert Enum.sum(dispositions) == statement["recorded_cents"]

      # The statement agrees with the ledger view.
      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 8000
      assert ledger["cash_retained_cents"] == 4000
      assert ledger["cash_reduced_cents"] == 1000

      # Reading a statement never changes state.
      assert get_payment(conn, "op-pay") == statement
      assert get_group(conn, "group-81")["revision"] == 4
    end

    test "all seven monetary fields are present when zero", %{conn: conn} do
      open_group(conn)
      pay(conn)

      statement = get_payment(conn, "op-pay")

      assert Map.keys(statement) |> Enum.sort() ==
               ~w(charged_back_cents converted_to_credit_cents held_cents original_group_id payment_operation_id recorded_cents reduced_cents refunded_cents retained_cents)
               |> Enum.sort()

      assert statement["held_cents"] == 5000
      assert statement["refunded_cents"] == 0
      assert statement["retained_cents"] == 0
      assert statement["converted_to_credit_cents"] == 0
      assert statement["reduced_cents"] == 0
      assert statement["charged_back_cents"] == 0
    end

    test "returns 404 when no durable operation record exists", %{conn: conn} do
      assert conn |> get("/api/v1/payments/op-nobody") |> json_response(404) ==
               %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns 422 when the record is not an applied cash payment", %{conn: conn} do
      open_group(conn)

      # A non-payment operation.
      assert conn |> get("/api/v1/payments/op-open") |> json_response(422) ==
               %{"error" => %{"code" => "payment_not_reconcilable"}}

      # A rejected payment.
      single_result(conn, [
        %{
          "operation_id" => "op-pay-bad",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 0
        }
      ])

      assert conn |> get("/api/v1/payments/op-pay-bad") |> json_response(422) ==
               %{"error" => %{"code" => "payment_not_reconcilable"}}
    end
  end
end
