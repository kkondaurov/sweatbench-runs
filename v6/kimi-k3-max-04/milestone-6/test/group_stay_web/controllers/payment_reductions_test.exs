defmodule GroupStayWeb.PaymentReductionsTest do
  @moduledoc """
  `reduce_cash_payment` and `charge_back_payment`
  (docs/requests/04-room-accounting-and-payment-reductions.md).
  """
  use GroupStayWeb.ConnCase, async: false

  # Helpers -----------------------------------------------------------------

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group_view(conn, group_id) do
    conn
    |> get(~p"/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get(~p"/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id) do
    conn
    |> get(~p"/api/v1/guests/#{guest_id}/credit")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # Two rooms, three nights: room-a due 9000, room-b due 10500 (total 19500).
  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
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
  end

  defp payment_op(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "record_cash_payment",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp cancel_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id
      },
      overrides
    )
  end

  defp reduce_op(payment_operation_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "reduce_cash_payment",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp charge_back_op(payment_operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "charge_back_payment",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  defp next_id, do: "op-#{System.unique_integer([:positive])}"
  defp uniq(suffix), do: "group-#{suffix}-#{System.unique_integer([:positive])}"

  # reduce_cash_payment -------------------------------------------------------

  describe "reduce_cash_payment" do
    test "rejects without a durable operation record", %{conn: conn} do
      [result] = submit(conn, [reduce_op("op-nope", 100)])
      assert %{"status" => "rejected", "code" => "operation_not_found"} = result
    end

    test "rejects non-payment operations as not reducible", %{conn: conn} do
      group_id = uniq("not-reducible")
      [open] = submit(conn, [open_op(group_id)])

      [result] = submit(conn, [reduce_op(open["operation_id"], 100)])
      assert %{"status" => "rejected", "code" => "payment_not_reducible"} = result
    end

    test "rejects rejected payments as not reducible", %{conn: conn} do
      group_id = uniq("rejected-payment")

      [_, rejected] = submit(conn, [open_op(group_id), payment_op(group_id, 0)])
      assert %{"status" => "rejected", "code" => "invalid_amount"} = rejected

      [result] = submit(conn, [reduce_op(rejected["operation_id"], 100)])
      assert %{"status" => "rejected", "code" => "payment_not_reducible"} = result
    end

    test "rejects a non-positive amount", %{conn: conn} do
      group_id = uniq("invalid-amount")
      [_, pay] = submit(conn, [open_op(group_id), payment_op(group_id, 5000)])

      for bad <- [0, -50, "100", 10.5] do
        [result] = submit(conn, [reduce_op(pay["operation_id"], bad)])
        assert %{"status" => "rejected", "code" => "invalid_amount"} = result
      end
    end

    test "rejects amounts above the held remainder with a stable code", %{conn: conn} do
      group_id = uniq("exceeds-held")
      [_, pay] = submit(conn, [open_op(group_id), payment_op(group_id, 5000)])

      [result] = submit(conn, [reduce_op(pay["operation_id"], 5001)])
      assert %{"status" => "rejected", "code" => "reduction_exceeds_held_cash"} = result
    end

    test "rejects when no held cash remains, even for a previously applied payment", %{
      conn: conn
    } do
      group_id = uniq("none-held")

      [_, pay, _cancel] =
        submit(conn, [open_op(group_id), payment_op(group_id, 5000), cancel_op(group_id)])

      [result] = submit(conn, [reduce_op(pay["operation_id"], 100)])
      assert %{"status" => "rejected", "code" => "payment_not_reducible"} = result
    end

    test "a payment recorded without an identifier cannot be reduced", %{conn: conn} do
      group_id = uniq("legacy")
      submit(conn, [open_op(group_id)])

      [pay] =
        submit(conn, [
          %{"type" => "record_cash_payment", "group_id" => group_id, "amount_cents" => 1000}
          |> Map.delete("operation_id")
        ])

      assert %{"status" => "applied", "operation_id" => nil} = pay

      [result] = submit(conn, [reduce_op("no-id", 100)])
      assert %{"status" => "rejected", "code" => "operation_not_found"} = result

      assert %{"cash_held_cents" => 1000} = ledger(conn)
    end

    test "removes held allocations in reverse fill order and reopens the deposit", %{conn: conn} do
      group_id = uniq("reverse")

      [_, pay1, pay2] =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 9000),
          payment_op(group_id, 900)
        ])

      assert %{"status" => "applied"} = pay1
      assert %{"status" => "applied"} = pay2

      [reduced] = submit(conn, [reduce_op(pay2["operation_id"], 700)])

      assert %{
               "status" => "applied",
               "amount_cents" => 700,
               "outstanding_deposit_cents" => 10300
             } = reduced

      # The second payment held room-b only; its 900 becomes 200.
      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 200}
               ],
               "deposit_paid_cents" => 9200,
               "outstanding_deposit_cents" => 10300
             } = group_view(conn, group_id)

      assert %{"cash_held_cents" => 9200, "cash_reduced_cents" => 700} = ledger(conn)
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      group_id = uniq("compose")
      [_, pay] = submit(conn, [open_op(group_id), payment_op(group_id, 5000)])

      [first] = submit(conn, [reduce_op(pay["operation_id"], 2000)])
      assert %{"status" => "applied", "revision" => 3} = first

      [overflow] = submit(conn, [reduce_op(pay["operation_id"], 3001)])
      assert %{"status" => "rejected", "code" => "reduction_exceeds_held_cash"} = overflow

      # The complete remaining held portion is a valid amount.
      [second] = submit(conn, [reduce_op(pay["operation_id"], 3000)])
      assert %{"status" => "applied", "revision" => 4} = second

      [exhausted] = submit(conn, [reduce_op(pay["operation_id"], 1)])
      assert %{"status" => "rejected", "code" => "payment_not_reducible"} = exhausted

      assert %{"cash_reduced_cents" => 5000, "cash_held_cents" => 0} = ledger(conn)
    end

    test "checks the revision against the original payment's group", %{conn: conn} do
      group_id = uniq("revision")
      [_, pay] = submit(conn, [open_op(group_id), payment_op(group_id, 5000)])

      [stale] = submit(conn, [reduce_op(pay["operation_id"], 100, %{"expected_revision" => 1})])

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => ^group_id,
               "expected_revision" => 1,
               "actual_revision" => 2
             } = stale

      [ok] = submit(conn, [reduce_op(pay["operation_id"], 100, %{"expected_revision" => 2})])
      assert %{"status" => "applied", "revision" => 3} = ok
    end

    test "never rewrites the payment's stored result", %{conn: conn} do
      group_id = uniq("stored")
      op = payment_op(group_id, 5000)
      [_, result] = submit(conn, [open_op(group_id), op])

      assert %{"status" => "applied", "outstanding_deposit_cents" => 14500} = result

      submit(conn, [reduce_op(op["operation_id"], 2000)])

      # The original payment still returns its exact original result.
      [replayed] = submit(conn, [op])
      assert replayed == result
      assert %{"revision" => 3} = group_view(conn, group_id)
    end
  end

  # charge_back_payment -------------------------------------------------------

  describe "charge_back_payment" do
    test "rejects an unknown operation id and only that code", %{conn: conn} do
      [result] = submit(conn, [charge_back_op("op-nope")])
      assert %{"status" => "rejected", "code" => "operation_not_found"} = result
    end

    test "reverses held cash and reopens the outstanding deposit", %{conn: conn} do
      group_id = uniq("cb-held")
      [_, pay] = submit(conn, [open_op(group_id), payment_op(group_id, 5000)])

      [chargeback] = submit(conn, [charge_back_op(pay["operation_id"])])

      assert %{
               "status" => "applied",
               "group_id" => ^group_id,
               "charged_back_cents" => 5000,
               "outstanding_deposit_cents" => 19500,
               "revision" => 3
             } = chargeback

      assert %{"cash_held_cents" => 0, "cash_charged_back_cents" => 5000} = ledger(conn)
      assert %{"revision" => 3} = group_view(conn, group_id)
    end

    test "rejects non-payment records, rejected payments, and repeats", %{conn: conn} do
      group_id = uniq("cb-rejects")
      [open] = submit(conn, [open_op(group_id)])

      # A recorded non-payment operation.
      [bad] = submit(conn, [charge_back_op(open["operation_id"])])
      assert %{"status" => "rejected", "code" => "payment_not_chargeable"} = bad

      # A recorded rejected payment.
      [rejected] = submit(conn, [payment_op(group_id, 0)])
      assert %{"status" => "rejected"} = rejected

      [bad2] = submit(conn, [charge_back_op(rejected["operation_id"])])
      assert %{"status" => "rejected", "code" => "payment_not_chargeable"} = bad2

      # An applied payment: one chargeback only.
      other_group = uniq("cb2")
      [_, pay] = submit(conn, [open_op(other_group), payment_op(other_group, 5000)])

      [ok] = submit(conn, [charge_back_op(pay["operation_id"])])
      assert %{"status" => "applied"} = ok

      [repeat] = submit(conn, [charge_back_op(pay["operation_id"])])
      assert %{"status" => "rejected", "code" => "payment_not_chargeable"} = repeat
    end

    test "a fully reduced payment cannot be charged back", %{conn: conn} do
      group_id = uniq("cb-reduced")
      [_, pay] = submit(conn, [open_op(group_id), payment_op(group_id, 5000)])

      submit(conn, [reduce_op(pay["operation_id"], 5000)])

      [result] = submit(conn, [charge_back_op(pay["operation_id"])])
      assert %{"status" => "rejected", "code" => "payment_not_chargeable"} = result
    end

    test "a cancelled group's payment can still be charged back", %{conn: conn} do
      group_id = uniq("cb-cancelled")

      [_, pay, _cancel] =
        submit(conn, [open_op(group_id), payment_op(group_id, 5000), cancel_op(group_id)])

      [chargeback] = submit(conn, [charge_back_op(pay["operation_id"])])

      assert %{"status" => "applied", "charged_back_cents" => 5000} = chargeback

      # The historical refund is reclassified; it is not reversed or reissued.
      assert %{"cash_refunded_cents" => 0, "cash_charged_back_cents" => 5000} = ledger(conn)
    end

    test "non-refundable retention reclassifies as charged back", %{conn: conn} do
      group_id = uniq("cb-retained")

      [_, pay, _cancel] =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 5000),
          cancel_op(group_id, %{"occurred_on" => "2026-11-27"})
        ])

      [chargeback] = submit(conn, [charge_back_op(pay["operation_id"])])

      assert %{"status" => "applied", "charged_back_cents" => 5000} = chargeback
      assert %{"cash_retained_cents" => 0, "cash_charged_back_cents" => 5000} = ledger(conn)
    end

    test "composed reduction plus chargeback moves the remaining dispositions", %{conn: conn} do
      group_id = uniq("cb-compose")
      [_, pay] = submit(conn, [open_op(group_id), payment_op(group_id, 5000)])

      submit(conn, [reduce_op(pay["operation_id"], 2000)])
      [chargeback] = submit(conn, [charge_back_op(pay["operation_id"])])

      # Reduction is settled history; only the remaining 3000 moves.
      assert %{"status" => "applied", "charged_back_cents" => 3000} = chargeback

      assert %{
               "cash_reduced_cents" => 2000,
               "cash_charged_back_cents" => 3000,
               "cash_held_cents" => 0
             } = ledger(conn)
    end

    test "revocation telescopes to the payment's entitlement", %{conn: conn} do
      group_id = uniq("cb-telescope")

      # pay1 = 100, pay2 = 8400 settle into one lot of 9350 with entitlements
      # 110 and 9240.
      [_, pay1, _pay2, settled] =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 100),
          payment_op(group_id, 8400),
          cancel_op(group_id, %{"refund_method" => "hotel_credit"})
        ])

      assert %{"status" => "applied", "credit_issued_cents" => 9350} = settled
      assert %{"available_cents" => 9350} = guest_credit(conn, "guest-22")

      [chargeback] = submit(conn, [charge_back_op(pay1["operation_id"])])
      assert %{"status" => "applied", "charged_back_cents" => 100} = chargeback

      # The lot now holds exactly pay2's entitlement.
      assert %{"available_cents" => 9240} = guest_credit(conn, "guest-22")

      assert %{
               "cash_charged_back_cents" => 100,
               "cash_converted_to_credit_cents" => 8400,
               "credit_liability_cents" => 9240,
               "credit_shortfall_cents" => 0
             } = ledger(conn)
    end

    test "spent entitlement becomes an unrecovered clawback and a current shortfall", %{
      conn: conn
    } do
      group_id = uniq("cb-shortfall")
      receiver = uniq("cb-receiver")

      [_, pay1, _pay2, settled] =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 100),
          payment_op(group_id, 8400),
          cancel_op(group_id, %{"refund_method" => "hotel_credit"})
        ])

      assert %{"credit_issued_cents" => 9350} = settled

      # A receiver spends 9241 of the 9350 lot, leaving 109 available.
      apply_credit_op = %{
        "operation_id" => next_id(),
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-27",
        "group_id" => receiver,
        "amount_cents" => 9241
      }

      submit(conn, [
        %{
          "operation_id" => next_id(),
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => receiver,
          "guest_id" => "guest-22",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rate_plan" => "flexible",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 20000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 30000}
          ]
        },
        apply_credit_op
      ])

      assert %{"available_cents" => 109} = guest_credit(conn, "guest-22")

      # Charging back pay1 (entitlement 110) recovers the 109 available; the
      # missing cent is unrecovered, and the lot's current shortfall is 1.
      [chargeback] = submit(conn, [charge_back_op(pay1["operation_id"])])
      assert %{"status" => "applied", "charged_back_cents" => 100} = chargeback

      assert %{"credit_shortfall_cents" => 1} = ledger(conn)

      # Credit returning to the lot extinguishes the shortfall first.
      submit(conn, [
        %{
          "operation_id" => next_id(),
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => receiver
        }
      ])

      assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 9240} = ledger(conn)
      assert %{"available_cents" => 9240} = guest_credit(conn, "guest-22")
    end
  end
end
