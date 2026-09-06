defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  describe "batch envelope" do
    test "returns one result per operation, in order" do
      results =
        submit([
          open_group(%{"operation_id" => "op-1", "group_id" => "group-1"}),
          open_group(%{"operation_id" => "op-2", "group_id" => "group-2"}),
          %{"operation_id" => "op-3", "type" => "nonsense"}
        ])

      assert Enum.map(results, & &1["operation_id"]) == ["op-1", "op-2", "op-3"]
      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "rejected"]
    end

    test "an empty operations array is a valid batch" do
      conn = submit_batch(%{"operations" => []})
      assert json_response(conn, 200) == %{"results" => []}
    end

    test "a body without an operations array is an invalid batch" do
      for body <- [%{}, %{"operations" => "nope"}, %{"ops" => []}] do
        conn = submit_batch(body)
        assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
      end
    end

    test "later operations observe changes made by earlier ones in the same batch" do
      [open, payment, too_much] =
        submit([
          open_group(%{"rooms" => [room("room-a", 10_000)], "departure_on" => "2026-12-11"}),
          record_cash_payment(%{"operation_id" => "op-pay-1", "amount_cents" => 500}),
          record_cash_payment(%{"operation_id" => "op-pay-2", "amount_cents" => 1_501})
        ])

      assert open["deposit_due_cents"] == 2_000
      assert payment["outstanding_deposit_cents"] == 1_500
      assert too_much["status"] == "rejected"
      assert too_much["code"] == "payment_exceeds_outstanding"
    end

    test "a rejected operation does not undo earlier work and does not stop later operations" do
      [_open, rejected, payment] =
        submit([
          open_group(),
          record_cash_payment(%{"operation_id" => "op-bad", "amount_cents" => -1}),
          record_cash_payment(%{"operation_id" => "op-good", "amount_cents" => 900_0})
        ])

      assert rejected["code"] == "invalid_amount"
      assert payment["status"] == "applied"

      {200, %{"data" => group}} = read_group("group-81")
      assert group["deposit_paid_cents"] == 9_000
      assert group["revision"] == 2
    end
  end

  describe "open_group" do
    test "prices the stay and reports the deposit" do
      result =
        submit_one(open_group(%{"rooms" => [room("room-a", 15_000), room("room-b", 17_500)]}))

      assert result == %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }

      {200, %{"data" => group}} = read_group("group-81")

      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 19_500
      assert group["booked_on"] == "2026-10-03"
      assert group["status"] == "active"
    end

    test "an advance purchase stay requires the full lodging amount" do
      result =
        submit_one(
          open_group(%{
            "rate_plan" => "advance_purchase",
            "rooms" => [room("room-a", 15_000), room("room-b", 17_500)]
          })
        )

      assert result["deposit_due_cents"] == 97_500

      {200, %{"data" => group}} = read_group("group-81")
      assert group["lodging_total_cents"] == 97_500
      assert group["rate_plan"] == "advance_purchase"
    end

    test "each room's deposit is rounded before the room deposits are summed" do
      # 12_343 cents of lodging is 2_468.6 cents of deposit: each room rounds up to 2_469,
      # while rounding the 24_686 cent group total once would give 4_937.
      result =
        submit_one(
          open_group(%{
            "departure_on" => "2026-12-11",
            "rooms" => [room("room-a", 12_343), room("room-b", 12_343)]
          })
        )

      assert result["deposit_due_cents"] == 4_938
    end

    test "rounds a deposit to the nearest cent" do
      for {rate, deposit} <- [{12_341, 2_468}, {12_343, 2_469}, {1, 0}, {3, 1}] do
        result =
          submit_one(
            open_group(%{
              "group_id" => "group-#{rate}",
              "departure_on" => "2026-12-11",
              "rooms" => [room("room-a", rate)]
            })
          )

        assert result["deposit_due_cents"] == deposit
      end
    end

    test "the lodging amount counts every night of the stay" do
      submit_one(
        open_group(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-20",
          "rooms" => [room("room-a", 10_000)]
        })
      )

      {200, %{"data" => group}} = read_group("group-81")
      assert group["lodging_total_cents"] == 100_000
      assert group["deposit_due_cents"] == 20_000
    end

    test "group identifiers are unique" do
      [_first, second] = submit([open_group(), open_group(%{"operation_id" => "op-again"})])

      assert second == %{
               "operation_id" => "op-again",
               "status" => "rejected",
               "code" => "group_already_exists"
             }
    end

    test "an existing group is not modified by a duplicate open_group" do
      submit_one(open_group())

      submit_one(
        open_group(%{
          "operation_id" => "op-again",
          "property_id" => "other",
          "rooms" => [room("room-z", 99_999)]
        })
      )

      {200, %{"data" => group}} = read_group("group-81")
      assert group["property_id"] == "ams-canal"
      assert group["revision"] == 1
      assert Enum.map(group["rooms"], & &1["room_id"]) == ["room-a"]
    end

    test "rejects a stay shorter than one night" do
      for departure <- ["2026-12-10", "2026-12-09", "not-a-date"] do
        result = submit_one(open_group(%{"departure_on" => departure}))
        assert result["code"] == "invalid_stay"
        assert {404, _} = read_group("group-81")
      end
    end

    test "rejects unusable rooms" do
      cases = [
        [],
        "room-a",
        [room("room-a", 10_000), room("room-a", 12_000)],
        [room("room-a", -1)],
        [room("room-a", "10000")],
        [%{"nightly_rate_cents" => 10_000}],
        [%{"room_id" => "room-a"}],
        [%{"room_id" => "", "nightly_rate_cents" => 10_000}]
      ]

      for rooms <- cases do
        result = submit_one(open_group(%{"rooms" => rooms}))
        assert result["code"] == "invalid_rooms", "expected invalid_rooms for #{inspect(rooms)}"
        assert {404, _} = read_group("group-81")
      end
    end

    test "rejects an unknown rate plan" do
      for rate_plan <- ["luxury", "", 7] do
        result = submit_one(open_group(%{"rate_plan" => rate_plan}))
        assert result["code"] == "invalid_rate_plan"
        assert {404, _} = read_group("group-81")
      end
    end

    test "a stay of zero-rate rooms is free and requires no deposit" do
      result = submit_one(open_group(%{"rooms" => [room("room-a", 0)]}))
      assert result["deposit_due_cents"] == 0

      {200, %{"data" => group}} = read_group("group-81")
      assert group["lodging_total_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0
    end
  end

  describe "invalid_operation" do
    test "rejects unknown and missing operation types" do
      for type <- ["transfer_group", "", nil, 3] do
        operation = Map.put(open_group(), "type", type)
        assert submit_one(operation)["code"] == "invalid_operation"
      end
    end

    test "rejects operations missing the data needed to identify them" do
      base = open_group()

      for key <- ["operation_id", "occurred_on", "group_id", "guest_id", "property_id"] do
        assert submit_one(Map.delete(base, key))["code"] == "invalid_operation",
               "expected invalid_operation without #{key}"
      end

      assert submit_one(Map.put(base, "occurred_on", "2026-13-40"))["code"] ==
               "invalid_operation"

      assert submit_one(Map.put(base, "group_id", 81))["code"] == "invalid_operation"
    end

    test "rejects operations missing the data needed to apply them" do
      submit_one(open_group())

      assert submit_one(Map.delete(open_group(%{"group_id" => "g-2"}), "rooms"))["code"] ==
               "invalid_operation"

      assert submit_one(Map.delete(open_group(%{"group_id" => "g-2"}), "arrival_on"))["code"] ==
               "invalid_operation"

      assert submit_one(Map.delete(open_group(%{"group_id" => "g-2"}), "rate_plan"))["code"] ==
               "invalid_operation"

      assert submit_one(Map.delete(record_cash_payment(), "amount_cents"))["code"] ==
               "invalid_operation"

      assert submit_one(Map.delete(reschedule_group(), "new_arrival_on"))["code"] ==
               "invalid_operation"

      {200, %{"data" => group}} = read_group("group-81")
      assert group["revision"] == 1
      assert {404, _} = read_group("g-2")
    end

    test "reports a missing operation identifier as null" do
      result = submit_one(Map.delete(open_group(), "operation_id"))

      assert result == %{
               "operation_id" => nil,
               "status" => "rejected",
               "code" => "invalid_operation"
             }
    end

    test "rejects operations that are not objects" do
      results = submit(["open_group", 42, nil, []])
      assert Enum.map(results, & &1["code"]) == List.duplicate("invalid_operation", 4)
      assert Enum.all?(results, &(&1["operation_id"] == nil))
    end
  end

  describe "record_cash_payment" do
    setup do
      submit_one(open_group(%{"rooms" => [room("room-a", 10_000)]}))
      :ok
    end

    test "applies cash to the outstanding deposit" do
      result = submit_one(record_cash_payment(%{"amount_cents" => 2_000}))

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 2_000,
               "outstanding_deposit_cents" => 4_000,
               "revision" => 2
             }

      {200, %{"data" => group}} = read_group("group-81")
      assert group["deposit_paid_cents"] == 2_000
      assert group["outstanding_deposit_cents"] == 4_000
    end

    test "accepts a payment that settles the deposit exactly" do
      result = submit_one(record_cash_payment(%{"amount_cents" => 6_000}))
      assert result["outstanding_deposit_cents"] == 0
      assert read_ledger()["cash_held_cents"] == 6_000
    end

    test "rejects a payment beyond the outstanding deposit" do
      result = submit_one(record_cash_payment(%{"amount_cents" => 6_001}))
      assert result["code"] == "payment_exceeds_outstanding"

      {200, %{"data" => group}} = read_group("group-81")
      assert group["deposit_paid_cents"] == 0
      assert group["revision"] == 1
    end

    test "rejects an amount that is not usable as a payment" do
      for amount <- [0, -100, "500", 12.5] do
        result = submit_one(record_cash_payment(%{"amount_cents" => amount}))

        assert result["code"] == "invalid_amount",
               "expected invalid_amount for #{inspect(amount)}"
      end

      {200, %{"data" => group}} = read_group("group-81")
      assert group["revision"] == 1
    end

    test "rejects a payment for a missing group" do
      result = submit_one(record_cash_payment(%{"group_id" => "group-404"}))
      assert result["code"] == "group_not_found"
    end

    test "rejects a payment for a cancelled group" do
      submit_one(cancel_group())
      result = submit_one(record_cash_payment())
      assert result["code"] == "group_not_active"
    end
  end

  describe "reschedule_group" do
    setup do
      submit_one(open_group(%{"rooms" => [room("room-a", 10_000)]}))
      :ok
    end

    test "shifts departure by the same number of days and keeps the price" do
      result = submit_one(reschedule_group(%{"new_arrival_on" => "2026-12-17"}))

      assert result == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-17",
               "new_departure_on" => "2026-12-20",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-03",
               "revision" => 2
             }

      {200, %{"data" => group}} = read_group("group-81")
      assert group["arrival_on"] == "2026-12-17"
      assert group["departure_on"] == "2026-12-20"
      assert group["lodging_total_cents"] == 30_000
      assert group["deposit_due_cents"] == 6_000
    end

    test "moves a stay earlier as long as it is still ahead of the operation date" do
      result = submit_one(reschedule_group(%{"new_arrival_on" => "2026-10-06"}))

      assert result["new_arrival_on"] == "2026-10-06"
      assert result["new_departure_on"] == "2026-10-09"
    end

    test "rejects a new arrival that is not after the operation date" do
      for arrival <- ["2026-10-05", "2026-10-04", "someday", 20_261_217] do
        result = submit_one(reschedule_group(%{"new_arrival_on" => arrival}))
        assert result["code"] == "invalid_stay", "expected invalid_stay for #{inspect(arrival)}"
      end

      {200, %{"data" => group}} = read_group("group-81")
      assert group["arrival_on"] == "2026-12-10"
      assert group["revision"] == 1
    end

    test "rejects a reschedule for a missing or cancelled group" do
      assert submit_one(reschedule_group(%{"group_id" => "group-404"}))["code"] ==
               "group_not_found"

      submit_one(cancel_group())
      assert submit_one(reschedule_group())["code"] == "group_not_active"
    end
  end

  describe "cancel_group" do
    test "refunds cash on a flexible stay cancelled at least 14 days before arrival" do
      submit([
        open_group(%{"rooms" => [room("room-a", 10_000)]}),
        record_cash_payment(%{"amount_cents" => 4_000})
      ])

      result = submit_one(cancel_group(%{"occurred_on" => "2026-11-26"}))

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 4_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert read_ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 4_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "retains cash on a flexible stay cancelled inside the refund window" do
      submit([
        open_group(%{"rooms" => [room("room-a", 10_000)]}),
        record_cash_payment(%{"amount_cents" => 4_000})
      ])

      result = submit_one(cancel_group(%{"occurred_on" => "2026-11-27"}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 4_000

      assert read_ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 4_000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "an advance purchase stay is never refundable" do
      submit([
        open_group(%{"rate_plan" => "advance_purchase", "rooms" => [room("room-a", 10_000)]}),
        record_cash_payment(%{"amount_cents" => 4_000})
      ])

      result = submit_one(cancel_group(%{"occurred_on" => "2026-10-06"}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 4_000
    end

    test "unpaid deposit is simply no longer due" do
      submit([
        open_group(%{"rooms" => [room("room-a", 10_000)]}),
        record_cash_payment(%{"amount_cents" => 1_000})
      ])

      submit_one(cancel_group())

      {200, %{"data" => group}} = read_group("group-81")
      assert group["status"] == "cancelled"
      assert group["deposit_due_cents"] == 6_000
      assert group["deposit_paid_cents"] == 1_000
      assert group["outstanding_deposit_cents"] == 0
    end

    test "a cancelled group cannot be paid, moved, or cancelled again" do
      submit_one(open_group())
      assert submit_one(cancel_group())["status"] == "applied"

      for operation <- [record_cash_payment(), reschedule_group(), cancel_group()] do
        assert submit_one(operation)["code"] == "group_not_active"
      end

      {200, %{"data" => group}} = read_group("group-81")
      assert group["revision"] == 2
    end

    test "rejects a cancellation for a missing group" do
      assert submit_one(cancel_group(%{"group_id" => "group-404"}))["code"] == "group_not_found"
    end
  end

  describe "revisions" do
    setup do
      submit_one(open_group(%{"rooms" => [room("room-a", 10_000)]}))
      :ok
    end

    test "every applied operation addressed to the group increments the revision once" do
      results =
        submit([
          record_cash_payment(%{"operation_id" => "op-1", "amount_cents" => 1_000}),
          reschedule_group(%{"operation_id" => "op-2"}),
          cancel_group(%{"operation_id" => "op-3"})
        ])

      assert Enum.map(results, & &1["revision"]) == [2, 3, 4]

      {200, %{"data" => group}} = read_group("group-81")
      assert group["revision"] == 4
    end

    test "a reschedule that does not change the stay still increments the revision" do
      result = submit_one(reschedule_group(%{"new_arrival_on" => "2026-12-10"}))

      assert result["revision"] == 2
      assert result["new_departure_on"] == "2026-12-13"
    end

    test "applies an operation whose expected_revision matches" do
      result = submit_one(record_cash_payment(%{"expected_revision" => 1}))
      assert result["status"] == "applied"
      assert result["revision"] == 2
    end

    test "rejects a stale revision with the current revision" do
      submit_one(record_cash_payment(%{"operation_id" => "op-first", "amount_cents" => 1_000}))

      result = submit_one(record_cash_payment(%{"expected_revision" => 1}))

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      {200, %{"data" => group}} = read_group("group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 1_000
      assert read_ledger()["cash_held_cents"] == 1_000
    end

    test "sees revisions changed earlier in the same batch" do
      results =
        submit([
          record_cash_payment(%{
            "operation_id" => "op-1",
            "amount_cents" => 1_000,
            "expected_revision" => 1
          }),
          record_cash_payment(%{
            "operation_id" => "op-2",
            "amount_cents" => 1_000,
            "expected_revision" => 1
          }),
          record_cash_payment(%{
            "operation_id" => "op-3",
            "amount_cents" => 1_000,
            "expected_revision" => 2
          })
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "rejected", "applied"]
      assert Enum.at(results, 1)["actual_revision"] == 2
      assert Enum.at(results, 2)["revision"] == 3
    end

    test "resolves group existence before comparing revisions" do
      result =
        submit_one(record_cash_payment(%{"group_id" => "group-404", "expected_revision" => 9}))

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "group_not_found"
             }
    end

    test "rejects a stale revision before other domain rules" do
      submit_one(cancel_group(%{"operation_id" => "op-cancel-first"}))

      result =
        submit_one(record_cash_payment(%{"amount_cents" => 999_999, "expected_revision" => 1}))

      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 2
    end

    test "reports the group's own errors when the expected revision matches" do
      result =
        submit_one(record_cash_payment(%{"amount_cents" => 999_999, "expected_revision" => 1}))

      assert result["code"] == "payment_exceeds_outstanding"
    end

    test "an unusable expected_revision cannot identify a revision to compare" do
      for expected <- ["1", 0, -1, 1.0] do
        result = submit_one(record_cash_payment(%{"expected_revision" => expected}))
        assert result["code"] == "invalid_operation"
      end
    end

    test "reschedules and cancellations honour the same revision contract" do
      stale_move = submit_one(reschedule_group(%{"expected_revision" => 2}))
      assert stale_move["code"] == "stale_revision"
      assert stale_move["actual_revision"] == 1

      stale_cancel = submit_one(cancel_group(%{"expected_revision" => 2}))
      assert stale_cancel["code"] == "stale_revision"

      {200, %{"data" => group}} = read_group("group-81")
      assert group["status"] == "active"
      assert group["arrival_on"] == "2026-12-10"
      assert group["revision"] == 1

      assert submit_one(reschedule_group(%{"expected_revision" => 1}))["revision"] == 2
      assert submit_one(cancel_group(%{"expected_revision" => 2}))["revision"] == 3
    end

    test "open_group ignores expected_revision and always creates revision 1" do
      result =
        submit_one(open_group(%{"group_id" => "group-new", "expected_revision" => 7}))

      assert result["revision"] == 1
    end
  end

  describe "policy versions" do
    test "a flexible group booked before 2027 keeps the 14-day window" do
      submit_one(
        open_group(%{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })
      )

      {200, %{"data" => group}} = read_group("group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-02-24"
    end

    test "a flexible group booked from 2027 on uses the 30-day window" do
      submit_one(
        open_group(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })
      )

      {200, %{"data" => group}} = read_group("group-81")
      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-02-08"
    end

    test "an advance purchase group is never refundable" do
      submit_one(
        open_group(%{
          "occurred_on" => "2027-01-05",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })
      )

      {200, %{"data" => group}} = read_group("group-81")
      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "a 30-day group is refundable through its refundable_until date and not after" do
      for {occurred_on, refunded, retained} <- [
            {"2027-02-08", 1_000, 0},
            {"2027-02-09", 0, 1_000}
          ] do
        group_id = "group-" <> occurred_on

        [_open, _pay, cancelled] =
          submit([
            open_group(%{
              "operation_id" => "op-open-" <> group_id,
              "group_id" => group_id,
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-10",
              "departure_on" => "2027-03-13",
              "rooms" => [room("room-a", 10_000)]
            }),
            record_cash_payment(%{
              "operation_id" => "op-pay-" <> group_id,
              "group_id" => group_id,
              "occurred_on" => "2027-01-02",
              "amount_cents" => 1_000
            }),
            cancel_group(%{
              "operation_id" => "op-cancel-" <> group_id,
              "group_id" => group_id,
              "occurred_on" => occurred_on
            })
          ])

        assert cancelled["refunded_cents"] == refunded
        assert cancelled["retained_cents"] == retained
      end
    end

    test "rescheduling moves the refundable date but never the policy" do
      submit_one(
        open_group(%{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })
      )

      result =
        submit_one(
          reschedule_group(%{"occurred_on" => "2027-01-10", "new_arrival_on" => "2027-04-10"})
        )

      assert result["policy_version"] == "flex-14"
      assert result["refundable_until"] == "2027-03-27"
      assert result["new_departure_on"] == "2027-04-13"

      {200, %{"data" => group}} = read_group("group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-03-27"
    end

    test "an advance purchase reschedule reports no refundable date" do
      submit_one(open_group(%{"rate_plan" => "advance_purchase"}))

      result = submit_one(reschedule_group(%{"new_arrival_on" => "2026-12-17"}))
      assert result["policy_version"] == "advance-nonrefundable"
      assert result["refundable_until"] == nil
    end
  end

  describe "cancel_group with a refund method" do
    setup do
      submit([
        open_group(%{"rooms" => [room("room-a", 10_000)]}),
        record_cash_payment(%{"amount_cents" => 4_000})
      ])

      :ok
    end

    test "converts refundable cash to a credit lot worth 110%" do
      result =
        submit_one(
          cancel_group(%{
            "operation_id" => "cancel-17",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        )

      assert result == %{
               "operation_id" => "cancel-17",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 4_400,
               "revision" => 3
             }

      assert read_credit("guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 4_400,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 4_400,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      assert read_ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 4_000,
               "credit_liability_cents" => 4_400
             }
    end

    test "an explicit cash refund method behaves like omitting it" do
      result =
        submit_one(cancel_group(%{"occurred_on" => "2026-11-26", "refund_method" => "cash"}))

      assert result["refunded_cents"] == 4_000
      assert result["credit_issued_cents"] == 0
      assert read_credit("guest-22")["available_cents"] == 0
      assert read_ledger()["cash_converted_to_credit_cents"] == 0
    end

    test "a non-refundable cancellation cannot take hotel credit" do
      result =
        submit_one(
          cancel_group(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
        )

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      {200, %{"data" => group}} = read_group("group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2
      assert read_ledger()["cash_held_cents"] == 4_000
    end

    test "an advance purchase cancellation cannot take hotel credit either" do
      submit([
        open_group(%{
          "operation_id" => "op-open-ap",
          "group_id" => "group-ap",
          "rate_plan" => "advance_purchase",
          "rooms" => [room("room-a", 10_000)]
        }),
        record_cash_payment(%{"group_id" => "group-ap", "amount_cents" => 4_000})
      ])

      result =
        submit_one(
          cancel_group(%{
            "group_id" => "group-ap",
            "occurred_on" => "2026-10-06",
            "refund_method" => "hotel_credit"
          })
        )

      assert result["code"] == "refund_method_not_available"

      {200, %{"data" => group}} = read_group("group-ap")
      assert group["status"] == "active"
    end

    test "rounds the 10% bonus to the nearest cent" do
      for {cash, credit} <- [{1_005, 1_106}, {1_004, 1_104}, {5, 6}, {4, 4}] do
        group_id = "group-bonus-#{cash}"

        [_open, _pay, cancelled] =
          submit([
            open_group(%{
              "group_id" => group_id,
              "departure_on" => "2026-12-11",
              "rooms" => [room("room-a", cash * 5)]
            }),
            record_cash_payment(%{"group_id" => group_id, "amount_cents" => cash}),
            cancel_group(%{
              "operation_id" => "cancel-#{cash}",
              "group_id" => group_id,
              "occurred_on" => "2026-11-26",
              "refund_method" => "hotel_credit"
            })
          ])

        assert cancelled["credit_issued_cents"] == credit,
               "expected #{credit} of credit for #{cash} of cash"
      end
    end

    test "converting no cash issues no credit and no lot" do
      submit_one(open_group(%{"group_id" => "group-empty", "rooms" => [room("room-a", 10_000)]}))

      result =
        submit_one(
          cancel_group(%{
            "operation_id" => "cancel-empty",
            "group_id" => "group-empty",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        )

      assert result["credit_issued_cents"] == 0
      assert read_credit("guest-22")["lots"] == []
    end

    test "rejects a refund method that is not offered" do
      for method <- ["voucher", "", 7, ["cash"]] do
        result = submit_one(cancel_group(%{"refund_method" => method}))

        assert result["code"] == "invalid_operation",
               "expected invalid_operation for #{inspect(method)}"
      end

      {200, %{"data" => group}} = read_group("group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2
    end

    test "a stale revision is rejected before the refund method" do
      result =
        submit_one(
          cancel_group(%{
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit",
            "expected_revision" => 1
          })
        )

      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 2
    end
  end

  describe "apply_hotel_credit" do
    setup do
      issue_credit(group_id: "group-source", cash_cents: 5_000, operation_id: "cancel-17")

      submit_one(open_group(%{"rooms" => [room("room-a", 15_000)]}))

      :ok
    end

    test "redeems credit into the outstanding deposit" do
      result = submit_one(apply_hotel_credit(%{"amount_cents" => 3_000}))

      assert result == %{
               "operation_id" => "op-credit",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 3_000,
               "outstanding_deposit_cents" => 6_000,
               "revision" => 2
             }

      {200, %{"data" => group}} = read_group("group-81")
      assert group["deposit_paid_cents"] == 3_000
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 3_000
      assert group["outstanding_deposit_cents"] == 6_000

      assert read_credit("guest-22")["available_cents"] == 2_500
    end

    test "cash and credit fund the same deposit" do
      submit([
        record_cash_payment(%{"amount_cents" => 4_000}),
        apply_hotel_credit(%{"amount_cents" => 5_000})
      ])

      {200, %{"data" => group}} = read_group("group-81")
      assert group["cash_paid_cents"] == 4_000
      assert group["credit_paid_cents"] == 5_000
      assert group["deposit_paid_cents"] == 9_000
      assert group["outstanding_deposit_cents"] == 0

      assert read_ledger()["cash_held_cents"] == 4_000
    end

    test "applying credit does not change the liability" do
      before = read_ledger()["credit_liability_cents"]
      assert before == 5_500

      submit_one(apply_hotel_credit(%{"amount_cents" => 3_000}))

      assert read_ledger()["credit_liability_cents"] == 5_500
      assert read_credit("guest-22")["available_cents"] == 2_500
    end

    test "rejects more credit than the guest holds" do
      result = submit_one(apply_hotel_credit(%{"amount_cents" => 5_501}))

      assert result == %{
               "operation_id" => "op-credit",
               "status" => "rejected",
               "code" => "insufficient_credit"
             }

      {200, %{"data" => group}} = read_group("group-81")
      assert group["revision"] == 1
      assert group["credit_paid_cents"] == 0
      assert read_credit("guest-22")["available_cents"] == 5_500
    end

    test "rejects credit beyond the outstanding deposit" do
      submit_one(record_cash_payment(%{"amount_cents" => 8_000}))

      result = submit_one(apply_hotel_credit(%{"amount_cents" => 1_001}))
      assert result["code"] == "payment_exceeds_outstanding"

      assert read_credit("guest-22")["available_cents"] == 5_500
    end

    test "rejects an amount that is not usable as a payment" do
      for amount <- [0, -100, "500", 12.5] do
        result = submit_one(apply_hotel_credit(%{"amount_cents" => amount}))

        assert result["code"] == "invalid_amount",
               "expected invalid_amount for #{inspect(amount)}"
      end

      assert submit_one(Map.delete(apply_hotel_credit(), "amount_cents"))["code"] ==
               "invalid_operation"
    end

    test "rejects credit for a missing or cancelled group" do
      assert submit_one(apply_hotel_credit(%{"group_id" => "group-404"}))["code"] ==
               "group_not_found"

      submit_one(cancel_group())
      assert submit_one(apply_hotel_credit())["code"] == "group_not_active"
    end

    test "credit from another guest cannot be spent" do
      submit_one(
        open_group(%{
          "operation_id" => "op-open-other",
          "group_id" => "group-other",
          "guest_id" => "guest-99",
          "rooms" => [room("room-a", 15_000)]
        })
      )

      assert submit_one(apply_hotel_credit(%{"group_id" => "group-other"}))["code"] ==
               "insufficient_credit"
    end

    test "expired credit cannot be applied" do
      assert submit_one(apply_hotel_credit(%{"occurred_on" => "2027-11-26"}))["status"] ==
               "applied"

      assert submit_one(
               apply_hotel_credit(%{"operation_id" => "op-late", "occurred_on" => "2027-11-27"})
             )["code"] == "insufficient_credit"
    end

    test "follows the revision contract" do
      stale = submit_one(apply_hotel_credit(%{"expected_revision" => 2}))
      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 1

      assert submit_one(apply_hotel_credit(%{"expected_revision" => 1}))["revision"] == 2
    end

    test "a stale revision is rejected before insufficient credit" do
      submit_one(record_cash_payment(%{"amount_cents" => 1_000}))

      result =
        submit_one(apply_hotel_credit(%{"amount_cents" => 999_999, "expected_revision" => 1}))

      assert result["code"] == "stale_revision"
    end

    test "consumes lots by expiry, then by source operation id" do
      issue_credit(
        group_id: "group-late",
        cash_cents: 1_000,
        operation_id: "cancel-01",
        cancelled_on: "2026-11-27"
      )

      issue_credit(
        group_id: "group-same",
        cash_cents: 1_000,
        operation_id: "cancel-02",
        cancelled_on: "2026-11-26"
      )

      # cancel-02 shares its expiry with cancel-17 and sorts after it; cancel-01 expires a day later.
      assert Enum.map(read_credit("guest-22")["lots"], & &1["source_operation_id"]) ==
               ["cancel-02", "cancel-17", "cancel-01"]

      submit_one(apply_hotel_credit(%{"amount_cents" => 2_000}))

      assert read_credit("guest-22")["lots"] == [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 4_600,
                 "expires_on" => "2027-11-26"
               },
               %{
                 "source_operation_id" => "cancel-01",
                 "remaining_cents" => 1_100,
                 "expires_on" => "2027-11-27"
               }
             ]
    end

    test "draws from as many lots as the amount needs" do
      issue_credit(group_id: "group-extra", cash_cents: 1_000, operation_id: "cancel-99")

      submit_one(apply_hotel_credit(%{"amount_cents" => 6_000}))

      assert read_credit("guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 600,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-99",
                   "remaining_cents" => 600,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }
    end
  end

  describe "settling a group funded by credit" do
    setup do
      issue_credit(group_id: "group-source", cash_cents: 5_000, operation_id: "cancel-17")

      submit([
        open_group(%{"rooms" => [room("room-a", 15_000)]}),
        record_cash_payment(%{"amount_cents" => 4_000}),
        apply_hotel_credit(%{"amount_cents" => 5_000})
      ])

      :ok
    end

    test "a refundable cash cancellation refunds cash and restores credit" do
      result = submit_one(cancel_group(%{"occurred_on" => "2026-11-26"}))

      assert result["refunded_cents"] == 4_000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert read_credit("guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 5_500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      assert read_ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 4_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5_000,
               "credit_liability_cents" => 5_500
             }
    end

    test "restored credit never receives a second bonus" do
      submit_one(
        cancel_group(%{
          "operation_id" => "cancel-again",
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
      )

      # The 4_000 of cash becomes a 4_400 lot; the 5_000 of credit goes back untouched.
      assert read_credit("guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 9_900,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-11-26"
                 },
                 %{
                   "source_operation_id" => "cancel-again",
                   "remaining_cents" => 4_400,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      assert read_ledger()["credit_liability_cents"] == 9_900
      assert read_ledger()["cash_converted_to_credit_cents"] == 9_000
    end

    test "a non-refundable cancellation retains cash and consumes credit" do
      result = submit_one(cancel_group(%{"occurred_on" => "2026-11-27"}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 4_000
      assert result["credit_issued_cents"] == 0

      assert read_credit("guest-22")["available_cents"] == 500
      assert read_ledger()["credit_liability_cents"] == 500
    end

    test "credit restored into a lot that already expired expires immediately" do
      # The lot expires on 2027-11-26, and the group is still refundable well past that.
      submit_one(
        reschedule_group(%{"occurred_on" => "2027-11-27", "new_arrival_on" => "2028-03-10"})
      )

      result = submit_one(cancel_group(%{"occurred_on" => "2027-12-01"}))

      assert result["refunded_cents"] == 4_000

      # Only the 500 the lot never lent out survives; the restored 5_000 expired with its lot.
      assert read_credit("guest-22")["available_cents"] == 500
      assert read_ledger()["credit_liability_cents"] == 500

      assert read_credit("guest-22", %{"on" => "2027-12-01"}) == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }

      assert read_ledger(%{"on" => "2027-12-01"})["credit_liability_cents"] == 0
    end

    test "credit drawn from several lots goes back to each of them" do
      issue_credit(
        group_id: "group-second",
        cash_cents: 1_000,
        operation_id: "cancel-99",
        cancelled_on: "2026-11-20"
      )

      # The setup already spent 5_000 of the first lot, so 500 is left beside the new 1_100.
      before = read_credit("guest-22")["lots"]

      assert before == [
               %{
                 "source_operation_id" => "cancel-99",
                 "remaining_cents" => 1_100,
                 "expires_on" => "2027-11-20"
               },
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 500,
                 "expires_on" => "2027-11-26"
               }
             ]

      [_open, applied] =
        submit([
          open_group(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-2",
            "rooms" => [room("room-a", 15_000)]
          }),
          apply_hotel_credit(%{"group_id" => "group-2", "amount_cents" => 1_500})
        ])

      assert applied["status"] == "applied"

      # 1_100 came from the earlier-expiring lot and 400 from the other.
      assert read_credit("guest-22")["lots"] == [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 100,
                 "expires_on" => "2027-11-26"
               }
             ]

      submit_one(
        cancel_group(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-11-26"
        })
      )

      assert read_credit("guest-22")["lots"] == before
    end

    test "the cancelled group keeps the split it was funded with" do
      submit_one(cancel_group(%{"occurred_on" => "2026-11-26"}))

      {200, %{"data" => group}} = read_group("group-81")
      assert group["status"] == "cancelled"
      assert group["cash_paid_cents"] == 4_000
      assert group["credit_paid_cents"] == 5_000
      assert group["deposit_paid_cents"] == 9_000
      assert group["outstanding_deposit_cents"] == 0
    end
  end
end
