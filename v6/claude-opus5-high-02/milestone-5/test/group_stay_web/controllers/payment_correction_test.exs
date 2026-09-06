defmodule GroupStayWeb.PaymentCorrectionTest do
  use GroupStayWeb.ConnCase, async: false

  # Rooms priced for one night, so room-a requires a 2_000 deposit and room-b 4_000.
  defp two_rooms(overrides \\ %{}) do
    open_group(
      Map.merge(
        %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [room("room-a", 10_000), room("room-b", 20_000)]
        },
        overrides
      )
    )
  end

  defp funded_group do
    submit([two_rooms(), record_cash_payment(%{"amount_cents" => 3_000})])
  end

  describe "reduce_cash_payment" do
    test "removes the payment's held cash latest-filled room first" do
      funded_group()

      result = submit_one(reduce_cash_payment(%{"amount_cents" => 1_500}))

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 1_500,
               "outstanding_deposit_cents" => 4_500,
               "revision" => 3
             }

      # room-b was filled last, so it gives its 1_000 up before room-a gives up 500.
      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 1_500},
               %{"room_id" => "room-b", "cash_paid_cents" => 0}
             ] = read_rooms("group-81")

      assert read_ledger()["cash_held_cents"] == 1_500
      assert read_ledger()["cash_reduced_cents"] == 1_500
    end

    test "successive reductions compose against what the payment still holds" do
      funded_group()

      submit([
        reduce_cash_payment(%{"operation_id" => "op-reduce-1", "amount_cents" => 1_000}),
        reduce_cash_payment(%{"operation_id" => "op-reduce-2", "amount_cents" => 1_500})
      ])

      assert read_ledger()["cash_reduced_cents"] == 2_500
      assert read_ledger()["cash_held_cents"] == 500

      # The whole remaining held portion is a valid reduction; nothing beyond it is.
      assert submit_one(
               reduce_cash_payment(%{"operation_id" => "op-reduce-3", "amount_cents" => 501})
             )["code"] == "reduction_exceeds_held_cash"

      assert submit_one(
               reduce_cash_payment(%{"operation_id" => "op-reduce-4", "amount_cents" => 500})
             )["status"] == "applied"

      assert read_ledger()["cash_held_cents"] == 0

      # With nothing held, no amount at all could be reduced.
      assert submit_one(
               reduce_cash_payment(%{"operation_id" => "op-reduce-5", "amount_cents" => 1})
             )["code"] == "payment_not_reducible"
    end

    test "only cash that is still held can be reduced" do
      funded_group()
      submit_one(cancel_rooms(%{"room_ids" => ["room-a"]}))

      # 2_000 of the payment is refunded history; only room-b's 1_000 is still held.
      assert submit_one(
               reduce_cash_payment(%{"operation_id" => "op-too-much", "amount_cents" => 1_500})
             )["code"] == "reduction_exceeds_held_cash"

      assert submit_one(
               reduce_cash_payment(%{"operation_id" => "op-ok", "amount_cents" => 1_000})
             )["amount_cents"] == 1_000

      assert read_ledger()["cash_refunded_cents"] == 2_000
      assert read_ledger()["cash_reduced_cents"] == 1_000
    end

    test "rejects a target it cannot correct" do
      funded_group()

      submit_one(
        record_cash_payment(%{"operation_id" => "op-rejected", "amount_cents" => 900_000})
      )

      for {operation_id, payment_operation_id, code} <- [
            {"op-missing", "op-never-seen", "operation_not_found"},
            {"op-not-a-payment", "op-open", "payment_not_reducible"},
            {"op-was-rejected", "op-rejected", "payment_not_reducible"}
          ] do
        result =
          submit_one(
            reduce_cash_payment(%{
              "operation_id" => operation_id,
              "payment_operation_id" => payment_operation_id
            })
          )

        assert result["code"] == code, "expected #{operation_id} to be #{code}"
      end
    end

    test "rejects an amount that is not a reduction" do
      funded_group()

      for {operation_id, amount} <- [{"op-zero", 0}, {"op-negative", -100}, {"op-text", "500"}] do
        result =
          submit_one(
            reduce_cash_payment(%{"operation_id" => operation_id, "amount_cents" => amount})
          )

        assert result["code"] == "invalid_amount"
      end

      assert read_ledger()["cash_held_cents"] == 3_000
    end

    test "follows the revision contract of the payment's own group" do
      funded_group()

      stale =
        submit_one(reduce_cash_payment(%{"operation_id" => "op-stale", "expected_revision" => 1}))

      assert stale == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert submit_one(
               reduce_cash_payment(%{"operation_id" => "op-fresh", "expected_revision" => 2})
             )["revision"] == 3
    end

    test "never rewrites the payment it corrects" do
      funded_group()
      submit_one(reduce_cash_payment(%{"amount_cents" => 1_000}))

      # The gateway retrying the original payment still receives what it was first told.
      retry = submit_one(record_cash_payment(%{"amount_cents" => 3_000}))

      assert retry == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 3_000,
               "outstanding_deposit_cents" => 3_000,
               "revision" => 2
             }

      assert {200, %{"data" => stored}} = read_operation("op-pay")
      assert stored == retry
      assert read_ledger()["cash_held_cents"] == 2_000
    end

    test "a retry reduces nothing a second time" do
      funded_group()

      first = submit_one(reduce_cash_payment(%{"amount_cents" => 1_000}))
      retry = submit_one(reduce_cash_payment(%{"amount_cents" => 1_000}))

      assert retry == first
      assert read_ledger()["cash_reduced_cents"] == 1_000
    end
  end

  describe "charge_back_payment" do
    test "reverses cash that is still held and reopens the deposit" do
      funded_group()

      result = submit_one(charge_back_payment())

      assert result == %{
               "operation_id" => "op-chargeback",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 3_000,
               "outstanding_deposit_cents" => 6_000,
               "revision" => 3
             }

      assert [%{"cash_paid_cents" => 0}, %{"cash_paid_cents" => 0}] = read_rooms("group-81")
      assert read_ledger()["cash_held_cents"] == 0
      assert read_ledger()["cash_charged_back_cents"] == 3_000
    end

    test "reclassifies cash that was already refunded or retained" do
      funded_group()
      submit_one(cancel_group())

      assert read_ledger()["cash_refunded_cents"] == 3_000

      result = submit_one(charge_back_payment())

      assert result["charged_back_cents"] == 3_000
      assert result["outstanding_deposit_cents"] == 0
      assert result["revision"] == 4

      assert read_ledger()["cash_refunded_cents"] == 0
      assert read_ledger()["cash_charged_back_cents"] == 3_000
    end

    test "reverses only what a reduction has not already taken" do
      funded_group()
      submit_one(reduce_cash_payment(%{"amount_cents" => 1_000}))

      assert submit_one(charge_back_payment())["charged_back_cents"] == 2_000

      assert read_ledger()["cash_reduced_cents"] == 1_000
      assert read_ledger()["cash_charged_back_cents"] == 2_000
    end

    test "revokes the credit the converted cash bought" do
      funded_group()
      submit_one(cancel_group(%{"refund_method" => "hotel_credit"}))

      assert read_credit("guest-22")["available_cents"] == 3_300

      assert submit_one(charge_back_payment())["charged_back_cents"] == 3_000

      assert read_credit("guest-22")["available_cents"] == 0
      assert read_ledger()["cash_converted_to_credit_cents"] == 0
      assert read_ledger()["credit_liability_cents"] == 0
      assert read_ledger()["credit_shortfall_cents"] == 0
    end

    test "splits one lot between the payments that funded it" do
      submit([
        two_rooms(%{"rooms" => [room("room-a", 500)]}),
        record_cash_payment(%{"operation_id" => "op-pay-1", "amount_cents" => 25}),
        record_cash_payment(%{"operation_id" => "op-pay-2", "amount_cents" => 25}),
        cancel_group(%{"refund_method" => "hotel_credit"})
      ])

      # One bonus on 50 makes a lot of 55, which the two payments share as 28 and 27.
      assert read_credit("guest-22")["available_cents"] == 55

      submit_one(charge_back_payment(%{"payment_operation_id" => "op-pay-2"}))
      assert read_credit("guest-22")["available_cents"] == 28

      submit_one(
        charge_back_payment(%{
          "operation_id" => "op-chargeback-1",
          "payment_operation_id" => "op-pay-1"
        })
      )

      assert read_credit("guest-22")["available_cents"] == 0
      assert read_ledger()["cash_charged_back_cents"] == 50
    end

    test "leaves a lot short when its credit is already spent elsewhere" do
      submit([
        two_rooms(%{"rooms" => [room("room-a", 500)]}),
        record_cash_payment(%{"operation_id" => "op-pay-1", "amount_cents" => 25}),
        record_cash_payment(%{"operation_id" => "op-pay-2", "amount_cents" => 25}),
        cancel_group(%{"refund_method" => "hotel_credit"}),
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [room("room-a", 1_000)]
        }),
        apply_hotel_credit(%{"group_id" => "group-2", "amount_cents" => 55})
      ])

      assert read_credit("guest-22")["available_cents"] == 0

      submit_one(charge_back_payment(%{"payment_operation_id" => "op-pay-2"}))

      # The lot cannot give back what it no longer holds, so it stays short until credit returns.
      assert read_ledger()["credit_shortfall_cents"] == 27
      assert read_ledger()["credit_liability_cents"] == 55

      # The chargeback settles the payment's own group only.
      assert {200, %{"data" => funded}} = read_group("group-2")
      assert funded["revision"] == 2
      assert funded["credit_paid_cents"] == 55

      submit_one(
        cancel_group(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-26"
        })
      )

      # The returning credit extinguishes the clawback before anything becomes available again.
      assert read_credit("guest-22")["available_cents"] == 28
      assert read_ledger()["credit_shortfall_cents"] == 0
      assert read_ledger()["credit_liability_cents"] == 28
    end

    test "a non-refundable settlement takes the shortfall with the credit it consumes" do
      submit([
        two_rooms(%{"rooms" => [room("room-a", 500)]}),
        record_cash_payment(%{"operation_id" => "op-pay-1", "amount_cents" => 25}),
        record_cash_payment(%{"operation_id" => "op-pay-2", "amount_cents" => 25}),
        cancel_group(%{"refund_method" => "hotel_credit"}),
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [room("room-a", 1_000)]
        }),
        apply_hotel_credit(%{"group_id" => "group-2", "amount_cents" => 55}),
        charge_back_payment(%{"payment_operation_id" => "op-pay-2"})
      ])

      assert read_ledger()["credit_shortfall_cents"] == 27

      submit_one(
        cancel_group(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-27"
        })
      )

      assert read_ledger()["credit_shortfall_cents"] == 0
      assert read_ledger()["credit_liability_cents"] == 0
    end

    test "credit returning to a short lot pays the clawback off before its expiry matters" do
      submit([
        two_rooms(%{"rooms" => [room("room-a", 500)]}),
        record_cash_payment(%{"operation_id" => "op-pay-1", "amount_cents" => 25}),
        record_cash_payment(%{"operation_id" => "op-pay-2", "amount_cents" => 25}),
        # A lot of 55, available through 2027-11-26, spent across two later groups.
        cancel_group(%{"occurred_on" => "2026-11-26", "refund_method" => "hotel_credit"}),
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "arrival_on" => "2028-06-01",
          "departure_on" => "2028-06-02",
          "rooms" => [room("room-a", 50)]
        }),
        apply_hotel_credit(%{
          "operation_id" => "op-credit-2",
          "group_id" => "group-2",
          "amount_cents" => 10
        }),
        open_group(%{
          "operation_id" => "op-open-3",
          "group_id" => "group-3",
          "arrival_on" => "2028-06-01",
          "departure_on" => "2028-06-02",
          "rooms" => [room("room-a", 225)]
        }),
        apply_hotel_credit(%{
          "operation_id" => "op-credit-3",
          "group_id" => "group-3",
          "amount_cents" => 45
        }),
        charge_back_payment(%{"payment_operation_id" => "op-pay-2"})
      ])

      assert read_ledger()["credit_shortfall_cents"] == 27

      # This settlement lands after the lot expired, so its 10 can only pay the clawback down.
      submit_one(
        cancel_group(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2027-12-01"
        })
      )

      assert read_credit("guest-22")["available_cents"] == 0
      assert read_ledger()["credit_shortfall_cents"] == 17

      # This one lands while the lot is still open, so what is left over is usable again.
      submit_one(
        cancel_group(%{
          "operation_id" => "op-cancel-3",
          "group_id" => "group-3",
          "occurred_on" => "2027-06-01"
        })
      )

      assert read_credit("guest-22")["available_cents"] == 28
      assert read_ledger()["credit_shortfall_cents"] == 0
      assert read_ledger()["credit_liability_cents"] == 28
    end

    test "rejects a target it cannot reverse" do
      funded_group()

      submit([
        charge_back_payment(%{"operation_id" => "op-first"}),
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "rooms" => [room("room-a", 10_000)]
        }),
        record_cash_payment(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-2",
          "amount_cents" => 1_000
        }),
        reduce_cash_payment(%{
          "operation_id" => "op-reduce-all",
          "payment_operation_id" => "op-pay-2",
          "amount_cents" => 1_000
        })
      ])

      for {operation_id, payment_operation_id, code} <- [
            {"op-missing", "op-never-seen", "operation_not_found"},
            {"op-not-a-payment", "op-open", "payment_not_chargeable"},
            {"op-again", "op-pay", "payment_not_chargeable"},
            {"op-all-reduced", "op-pay-2", "payment_not_chargeable"}
          ] do
        result =
          submit_one(
            charge_back_payment(%{
              "operation_id" => operation_id,
              "payment_operation_id" => payment_operation_id
            })
          )

        assert result["code"] == code, "expected #{operation_id} to be #{code}"
      end
    end

    test "a retry reverses nothing a second time" do
      funded_group()

      first = submit_one(charge_back_payment())
      retry = submit_one(charge_back_payment())

      assert retry == first
      assert read_ledger()["cash_charged_back_cents"] == 3_000
    end
  end

  describe "operations this release cannot identify" do
    test "are rejected as invalid_operation" do
      funded_group()

      operations = [
        Map.delete(cancel_rooms(%{"operation_id" => "op-1"}), "room_ids"),
        cancel_rooms(%{"operation_id" => "op-2", "refund_method" => "voucher"}),
        Map.delete(reduce_cash_payment(%{"operation_id" => "op-3"}), "payment_operation_id"),
        Map.delete(reduce_cash_payment(%{"operation_id" => "op-4"}), "amount_cents"),
        Map.delete(charge_back_payment(%{"operation_id" => "op-5"}), "payment_operation_id"),
        charge_back_payment(%{"operation_id" => "op-6", "payment_operation_id" => "  "})
      ]

      for result <- submit(operations) do
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end

      assert read_ledger()["cash_held_cents"] == 3_000
    end
  end

  describe "reading one payment" do
    test "reports where every cent of the payment currently sits" do
      submit([
        two_rooms(%{
          "rooms" => [room("room-a", 10_000), room("room-b", 20_000), room("room-c", 30_000)]
        }),
        record_cash_payment(%{"amount_cents" => 9_000}),
        cancel_rooms(%{"operation_id" => "op-cancel-a", "room_ids" => ["room-a"]}),
        cancel_rooms(%{
          "operation_id" => "op-cancel-b",
          "room_ids" => ["room-b"],
          "refund_method" => "hotel_credit"
        }),
        reduce_cash_payment(%{"amount_cents" => 1_000})
      ])

      assert {200, %{"data" => statement}} = read_payment("op-pay")

      assert statement == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 9_000,
               "held_cents" => 2_000,
               "refunded_cents" => 2_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 4_000,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 0
             }

      assert dispositions_sum(statement) == statement["recorded_cents"]

      # The statement agrees with the group and the ledger it was read beside.
      assert [_, _, %{"cash_paid_cents" => 2_000}] = read_rooms("group-81")
      assert read_ledger()["cash_held_cents"] == 2_000

      submit_one(charge_back_payment())

      assert {200, %{"data" => reversed}} = read_payment("op-pay")

      assert reversed == %{
               statement
               | "held_cents" => 0,
                 "refunded_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "charged_back_cents" => 8_000
             }

      assert dispositions_sum(reversed) == 9_000
      assert read_credit("guest-22")["available_cents"] == 0
    end

    test "reports zero dispositions for a payment nothing has happened to" do
      funded_group()

      assert {200, %{"data" => statement}} = read_payment("op-pay")

      assert statement == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 3_000,
               "held_cents" => 3_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
    end

    test "a payment that was never recorded is not found" do
      assert {404, body} = read_payment("op-never-seen")
      assert body == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "an operation that is not an applied cash payment cannot be reconciled" do
      funded_group()

      submit_one(
        record_cash_payment(%{"operation_id" => "op-rejected", "amount_cents" => 900_000})
      )

      for operation_id <- ["op-open", "op-rejected"] do
        assert {422, body} = read_payment(operation_id)
        assert body == %{"error" => %{"code" => "payment_not_reconcilable"}}
      end
    end
  end

  describe "the books after a long life" do
    test "the ledger, the rooms, and every payment statement still agree" do
      submit([
        two_rooms(%{
          "rooms" => [room("room-a", 10_000), room("room-b", 20_000), room("room-c", 30_000)]
        }),
        record_cash_payment(%{"operation_id" => "op-pay-a", "amount_cents" => 5_000}),
        record_cash_payment(%{"operation_id" => "op-pay-b", "amount_cents" => 4_000}),
        cancel_rooms(%{"operation_id" => "op-cancel-a", "room_ids" => ["room-a"]}),
        cancel_rooms(%{
          "operation_id" => "op-cancel-b",
          "room_ids" => ["room-b"],
          "refund_method" => "hotel_credit"
        }),
        reduce_cash_payment(%{
          "operation_id" => "op-reduce-b",
          "payment_operation_id" => "op-pay-b",
          "amount_cents" => 1_000
        }),
        charge_back_payment(%{"payment_operation_id" => "op-pay-a"})
      ])

      {200, %{"data" => first}} = read_payment("op-pay-a")
      {200, %{"data" => second}} = read_payment("op-pay-b")

      assert first["recorded_cents"] == 5_000
      assert first["charged_back_cents"] == 5_000
      assert dispositions_sum(first) == 5_000

      assert second == %{
               "payment_operation_id" => "op-pay-b",
               "original_group_id" => "group-81",
               "recorded_cents" => 4_000,
               "held_cents" => 2_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 1_000,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 0
             }

      ledger = read_ledger()

      for {statement_field, ledger_field} <- [
            {"held_cents", "cash_held_cents"},
            {"refunded_cents", "cash_refunded_cents"},
            {"retained_cents", "cash_retained_cents"},
            {"converted_to_credit_cents", "cash_converted_to_credit_cents"},
            {"reduced_cents", "cash_reduced_cents"},
            {"charged_back_cents", "cash_charged_back_cents"}
          ] do
        assert ledger[ledger_field] == first[statement_field] + second[statement_field],
               "#{ledger_field} disagrees with the payment statements"
      end

      # The cash the ledger still holds is the cash the active rooms are funded with.
      assert [_, _, %{"room_id" => "room-c", "cash_paid_cents" => 2_000}] = read_rooms("group-81")
      assert ledger["cash_held_cents"] == 2_000

      # Charging the first payment back took its share of the lot, and only its share.
      assert read_credit("guest-22")["available_cents"] == 1_100
      assert ledger["credit_liability_cents"] == 1_100
      assert ledger["credit_shortfall_cents"] == 0
    end
  end

  defp dispositions_sum(statement) do
    ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
    |> Enum.map(&statement[&1])
    |> Enum.sum()
  end
end
