defmodule GroupStayWeb.Acceptance.ReduceCashPaymentTest do
  use GroupStayWeb.ConnCase

  @guest "guest-22"

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  # Two rooms over two nights (flexible, 20% deposit):
  #   room-a lodging 20000 deposit 4000
  #   room-b lodging 30000 deposit 6000
  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => @guest,
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 15000}
        ]
      },
      overrides
    )
  end

  defp pay_op(op_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp reduce_op(op_id, payment_operation_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp payment(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  describe "applying a reduction" do
    test "removes held cash and reopens the outstanding deposit" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 7000)])

      assert [
               %{
                 "operation_id" => "reduce-1",
                 "status" => "applied",
                 "payment_operation_id" => "pay-1",
                 "group_id" => "group-a",
                 "amount_cents" => 2000,
                 "outstanding_deposit_cents" => 5000,
                 "revision" => 3
               }
             ] = submit(build_conn(), [reduce_op("reduce-1", "pay-1", 2000)])

      group = group(build_conn(), "group-a")
      assert group["deposit_paid_cents"] == 5000
      assert group["outstanding_deposit_cents"] == 5000

      assert ledger(build_conn())["cash_held_cents"] == 5000
      assert ledger(build_conn())["cash_reduced_cents"] == 2000
    end

    test "removes held allocations in reverse fill order" do
      # pay-1 fills room-a 4000 and room-b 3000; pay-2 fills room-b 2000.
      submit(build_conn(), [
        open_op("group-a"),
        pay_op("pay-1", "group-a", 7000),
        pay_op("pay-2", "group-a", 2000)
      ])

      # Reducing pay-1 by 5000 removes room-b's 3000 first, then 2000 from
      # room-a, leaving 2000 of pay-1 on room-a.
      assert [%{"status" => "applied"}] =
               submit(build_conn(), [reduce_op("reduce-1", "pay-1", 5000)])

      statement = payment(build_conn(), "pay-1")
      assert statement["held_cents"] == 2000
      assert statement["reduced_cents"] == 5000

      # pay-2 is untouched.
      assert payment(build_conn(), "pay-2")["held_cents"] == 2000
    end

    test "successive reductions compose against the remaining held cash" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 7000)])

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 5000}] =
               submit(build_conn(), [reduce_op("reduce-1", "pay-1", 2000)])

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 7000}] =
               submit(build_conn(), [reduce_op("reduce-2", "pay-1", 2000)])

      assert payment(build_conn(), "pay-1")["held_cents"] == 3000
      assert payment(build_conn(), "pay-1")["reduced_cents"] == 4000
    end

    test "an amount equal to the complete remaining held portion is valid" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 7000)])

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 10000}] =
               submit(build_conn(), [reduce_op("reduce-1", "pay-1", 7000)])

      statement = payment(build_conn(), "pay-1")
      assert statement["held_cents"] == 0
      assert statement["reduced_cents"] == 7000
    end

    test "does not move settled cash" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 7000)])

      submit(build_conn(), [
        %{
          "operation_id" => "cancel-group-a",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-01",
          "group_id" => "group-a"
        }
      ])

      # All of pay-1's cash was refunded; nothing is held any more.
      assert [%{"status" => "rejected", "code" => "payment_not_reducible"}] =
               submit(build_conn(), [reduce_op("reduce-1", "pay-1", 1000)])

      assert payment(build_conn(), "pay-1")["refunded_cents"] == 7000
    end
  end

  describe "rejections" do
    test "operation_not_found when no durable record exists" do
      submit(build_conn(), [open_op("group-a")])

      assert [%{"status" => "rejected", "code" => "operation_not_found"}] =
               submit(build_conn(), [reduce_op("reduce-1", "never-seen", 1000)])
    end

    test "payment_not_reducible for a non-payment operation" do
      submit(build_conn(), [open_op("group-a")])

      assert [%{"status" => "rejected", "code" => "payment_not_reducible"}] =
               submit(build_conn(), [reduce_op("reduce-1", "open-group-a", 1000)])
    end

    test "payment_not_reducible for a rejected payment" do
      submit(build_conn(), [open_op("group-a")])
      submit(build_conn(), [pay_op("pay-bad", "group-a", 0)])

      assert [%{"status" => "rejected", "code" => "payment_not_reducible"}] =
               submit(build_conn(), [reduce_op("reduce-1", "pay-bad", 1000)])
    end

    test "invalid_amount for a non-positive reduction" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 7000)])

      [0, -100, "1000", 10.5, nil]
      |> Enum.with_index()
      |> Enum.each(fn {amount, index} ->
        assert [%{"status" => "rejected", "code" => "invalid_amount"}] =
                 submit(build_conn(), [
                   reduce_op("reduce-invalid-#{index}", "pay-1", 1000, %{
                     "amount_cents" => amount
                   })
                 ])
      end)
    end

    test "reduction_exceeds_held_cash when the amount is too large" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 7000)])

      assert [%{"status" => "rejected", "code" => "reduction_exceeds_held_cash"}] =
               submit(build_conn(), [reduce_op("reduce-1", "pay-1", 7001)])

      # The group is unchanged.
      assert group(build_conn(), "group-a")["deposit_paid_cents"] == 7000
    end

    test "a missing amount is an invalid operation" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 7000)])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), [
                 reduce_op("reduce-1", "pay-1", 1000) |> Map.delete("amount_cents")
               ])
    end

    test "follows the revision contract against the payment's group" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 7000)])

      assert [%{"status" => "applied", "revision" => 3}] =
               submit(build_conn(), [
                 reduce_op("reduce-1", "pay-1", 1000, %{
                   "expected_revision" => 2
                 })
               ])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-a",
                 "expected_revision" => 2,
                 "actual_revision" => 3
               }
             ] =
               submit(build_conn(), [
                 reduce_op("reduce-2", "pay-1", 1000, %{"expected_revision" => 2})
               ])
    end
  end

  describe "durability" do
    test "a retry returns the stored result without reapplying" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 7000)])

      [first] = submit(build_conn(), [reduce_op("reduce-1", "pay-1", 2000)])
      assert first["status"] == "applied"

      assert submit(build_conn(), [reduce_op("reduce-1", "pay-1", 2000)]) == [first]

      # Only reduced once.
      assert payment(build_conn(), "pay-1")["reduced_cents"] == 2000
      assert group(build_conn(), "group-a")["deposit_paid_cents"] == 5000
    end

    test "never rewrites the target payment's stored result" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 7000)])
      [payment_result] = submit(build_conn(), [pay_op("pay-1", "group-a", 7000)])

      submit(build_conn(), [reduce_op("reduce-1", "pay-1", 2000)])

      # Retrying the original payment returns its exact original result.
      assert submit(build_conn(), [pay_op("pay-1", "group-a", 7000)]) == [payment_result]

      # The reduction still took effect.
      assert payment(build_conn(), "pay-1")["reduced_cents"] == 2000
    end
  end
end
