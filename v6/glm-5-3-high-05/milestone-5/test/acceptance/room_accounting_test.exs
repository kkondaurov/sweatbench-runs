defmodule GroupStayWeb.Acceptance.RoomAccountingTest do
  @moduledoc """
  Acceptance tests for the room-accounting request: room-level deposit and
  payment amounts, funding fill order, and settling selected rooms with
  `cancel_rooms`.
  """

  use GroupStayWeb.ConnCase, async: true

  describe "room-level accounting" do
    test "every room exposes its status, deposit, and paid amounts" do
      open_group!(build_conn())

      assert %{
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 15000,
                   "status" => "active",
                   "deposit_due_cents" => 9000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 17500,
                   "status" => "active",
                   "deposit_due_cents" => 10500,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 97500,
               "deposit_due_cents" => 19500
             } = group_data("group-81")
    end

    test "cash funds active room deposits in the rooms' original order" do
      open_group!(build_conn())

      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 12000}))

      assert %{
               "rooms" => [
                 %{"status" => "active", "cash_paid_cents" => 9000, "credit_paid_cents" => 0},
                 %{"status" => "active", "cash_paid_cents" => 3000, "credit_paid_cents" => 0}
               ],
               "cash_paid_cents" => 12000,
               "deposit_paid_cents" => 12000,
               "outstanding_deposit_cents" => 7500
             } = group_data("group-81")
    end

    test "later funding operations allocate in operation-processing order" do
      open_group!(build_conn())

      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9000})
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 3000})
      )

      assert %{
               "rooms" => [
                 %{"cash_paid_cents" => 9000},
                 %{"cash_paid_cents" => 3000}
               ]
             } = group_data("group-81")
    end

    test "credit fills one room's deposit before moving to the next" do
      open_group!(build_conn())
      fund_credit_lot("group-src", 10_000)

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"amount_cents" => 10_000})
      )

      assert %{
               "rooms" => [
                 %{"cash_paid_cents" => 0, "credit_paid_cents" => 9000},
                 %{"cash_paid_cents" => 0, "credit_paid_cents" => 1000}
               ],
               "credit_paid_cents" => 10_000,
               "outstanding_deposit_cents" => 9500
             } = group_data("group-81")
    end

    test "cash and credit share a room's deposit" do
      open_group!(build_conn())
      fund_credit_lot("group-src", 5000)

      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 9000}))

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"amount_cents" => 5000})
      )

      assert %{
               "rooms" => [
                 %{"cash_paid_cents" => 9000, "credit_paid_cents" => 0},
                 %{"cash_paid_cents" => 0, "credit_paid_cents" => 5000}
               ],
               "deposit_paid_cents" => 14_000
             } = group_data("group-81")
    end

    test "funding without a durable record settles as one unattributed block" do
      open_group!(build_conn())

      # An operation whose identifier cannot be keyed durably is applied but
      # leaves no operation record: its funding has no payment identity.
      payment =
        record_cash_operation(%{
          "operation_id" => %{"legacy" => true},
          "amount_cents" => 5000
        })

      assert %{"status" => "applied"} = apply_one!(build_conn(), payment)

      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{
            "operation_id" => "cancel-legacy",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        )

      assert %{"credit_issued_cents" => 5500} = result

      assert %{
               "cash_held_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             } = ledger()
    end
  end

  describe "cancel_rooms" do
    setup do
      open_group!(build_conn())

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "operation_id" => "op-pay-1",
          "amount_cents" => 12_000
        })
      )

      :ok
    end

    test "settles the selected rooms and leaves the others unchanged" do
      result =
        apply_one!(
          build_conn(),
          cancel_rooms_operation(%{
            "operation_id" => "op-cancel-rooms-1",
            "room_ids" => ["room-b"]
          })
        )

      assert result == %{
               "operation_id" => "op-cancel-rooms-1",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 3000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      # The group's totals describe active rooms only.
      assert %{
               "status" => "active",
               "revision" => 3,
               "lodging_total_cents" => 45_000,
               "deposit_due_cents" => 9000,
               "deposit_paid_cents" => 9000,
               "cash_paid_cents" => 9000,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 3000}
               ]
             } = group_data("group-81")

      assert %{"cash_held_cents" => 9000, "cash_refunded_cents" => 3000} = ledger()

      # The settled cash agrees with the payment statement.
      assert %{
               "held_cents" => 9000,
               "refunded_cents" => 3000
             } = payment_data("op-pay-1")
    end

    test "returns cancelled_room_ids in the group's original room order" do
      result =
        apply_one!(
          build_conn(),
          cancel_rooms_operation(%{"room_ids" => ["room-b", "room-a"]})
        )

      assert %{"cancelled_room_ids" => ["room-a", "room-b"], "refunded_cents" => 12_000} = result
      assert %{"status" => "cancelled", "revision" => 3} = group_data("group-81")
    end

    test "a non-refundable cancellation retains the selected rooms' cash" do
      result =
        apply_one!(
          build_conn(),
          cancel_rooms_operation(%{"room_ids" => ["room-b"], "occurred_on" => "2026-11-27"})
        )

      assert %{"refunded_cents" => 0, "retained_cents" => 3000, "revision" => 3} = result
      assert %{"status" => "active", "outstanding_deposit_cents" => 0} = group_data("group-81")
      assert %{"cash_held_cents" => 9000, "cash_retained_cents" => 3000} = ledger()
    end

    test "rejects hotel credit for a non-refundable cancellation" do
      result =
        apply_one!(
          build_conn(),
          cancel_rooms_operation(%{
            "room_ids" => ["room-b"],
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit"
          })
        )

      assert %{"status" => "rejected", "code" => "refund_method_not_available"} = result
      assert %{"status" => "active", "revision" => 2} = group_data("group-81")
    end

    test "computes the hotel-credit bonus once on the combined cash" do
      # Two one-night rooms at 525: each deposit is 105. A combined 210 cash
      # converts to one lot of 231, not two lots of 116.
      open_group!(build_conn(), %{
        "group_id" => "group-105",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 525},
          %{"room_id" => "room-b", "nightly_rate_cents" => 525}
        ]
      })

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-105", "amount_cents" => 210})
      )

      result =
        apply_one!(
          build_conn(),
          cancel_rooms_operation(%{
            "group_id" => "group-105",
            "room_ids" => ["room-a", "room-b"],
            "refund_method" => "hotel_credit"
          })
        )

      assert %{"credit_issued_cents" => 231, "refunded_cents" => 0, "retained_cents" => 0} =
               result

      assert %{
               "available_cents" => 231,
               "lots" => [%{"remaining_cents" => 231}]
             } = guest_credit("guest-22")

      assert %{"status" => "cancelled", "credit_paid_cents" => 0} = group_data("group-105")
    end

    test "restores the selected rooms' credit to its original lot" do
      open_group!(build_conn(), %{"group_id" => "group-restore"})
      fund_credit_lot("group-src", 5000)

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"group_id" => "group-restore", "amount_cents" => 5000})
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-restore", "amount_cents" => 9000})
      )

      # Credit fills room-a first (5000), then cash fills room-a's remaining
      # 4000 and room-b's 5000.
      result =
        apply_one!(
          build_conn(),
          cancel_rooms_operation(%{"group_id" => "group-restore", "room_ids" => ["room-a"]})
        )

      assert %{"refunded_cents" => 4000, "retained_cents" => 0} = result

      # The 5000 credit leaves room-a and is available again without a second
      # bonus; room-b keeps its 5000 of cash.
      assert %{
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "status" => "cancelled",
                   "credit_paid_cents" => 5000,
                   "cash_paid_cents" => 4000
                 },
                 %{
                   "room_id" => "room-b",
                   "status" => "active",
                   "credit_paid_cents" => 0,
                   "cash_paid_cents" => 5000
                 }
               ],
               "cash_paid_cents" => 5000,
               "outstanding_deposit_cents" => 5500
             } = group_data("group-restore")

      # The restored 5000 rejoins the lot's unspent 500.
      assert %{"available_cents" => 5500} = guest_credit("guest-22")
      assert %{"credit_liability_cents" => 5500} = ledger()
    end

    test "consumes the selected rooms' credit on a non-refundable settlement" do
      open_group!(build_conn(), %{"group_id" => "group-consume"})
      fund_credit_lot("group-src", 5000)

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"group_id" => "group-consume", "amount_cents" => 5000})
      )

      result =
        apply_one!(
          build_conn(),
          cancel_rooms_operation(%{
            "group_id" => "group-consume",
            "room_ids" => ["room-a"],
            "occurred_on" => "2026-11-27"
          })
        )

      assert %{"refunded_cents" => 0, "retained_cents" => 0} = result

      # The consumed 5000 is gone; the lot's unspent 500 remains.
      assert %{"available_cents" => 500} = guest_credit("guest-22")
      assert %{"credit_liability_cents" => 500} = ledger()
    end

    test "cancel_group settles only the remaining active rooms" do
      apply_one!(build_conn(), cancel_rooms_operation(%{"room_ids" => ["room-b"]}))

      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"occurred_on" => "2026-11-26"})
        )

      assert %{"refunded_cents" => 9000, "retained_cents" => 0, "revision" => 4} = result
      assert %{"status" => "cancelled", "cash_paid_cents" => 0} = group_data("group-81")

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 12_000
             } = ledger()
    end

    test "rejects unusable room selections with invalid_rooms" do
      open_group!(build_conn(), %{
        "group_id" => "group-other",
        "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 15000}]
      })

      for attrs <- [
            %{"room_ids" => ["room-z"]},
            %{"room_ids" => ["room-a", "room-a"]},
            %{"room_ids" => []},
            %{"room_ids" => ["room-a", 1]},
            %{"room_ids" => "room-a"},
            %{"room_ids" => nil},
            %{"room_ids" => ["room-x"]}
          ] do
        result = apply_one!(build_conn(), cancel_rooms_operation(attrs))
        assert %{"status" => "rejected", "code" => "invalid_rooms"} = result
      end

      assert %{"status" => "active", "revision" => 2} = group_data("group-81")
    end

    test "rejects a room that was already cancelled" do
      apply_one!(build_conn(), cancel_rooms_operation(%{"room_ids" => ["room-b"]}))

      result =
        apply_one!(
          build_conn(),
          cancel_rooms_operation(%{"room_ids" => ["room-b"]})
        )

      assert %{"status" => "rejected", "code" => "invalid_rooms"} = result
      assert %{"status" => "active", "revision" => 3} = group_data("group-81")
    end

    test "rejects a cancelled group before evaluating room selections" do
      apply_one!(build_conn(), cancel_operation(%{"occurred_on" => "2026-11-26"}))

      result = apply_one!(build_conn(), cancel_rooms_operation(%{"room_ids" => ["room-a"]}))

      assert %{"status" => "rejected", "code" => "group_not_active"} = result
    end

    test "follows the revision contract" do
      result =
        apply_one!(
          build_conn(),
          cancel_rooms_operation(%{"room_ids" => ["room-b"], "expected_revision" => 2})
        )

      assert %{"status" => "applied", "revision" => 3} = result

      result =
        apply_one!(
          build_conn(),
          cancel_rooms_operation(%{"room_ids" => ["room-a"], "expected_revision" => 2})
        )

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "expected_revision" => 2,
               "actual_revision" => 3
             } = result
    end

    test "is durably idempotent" do
      operation =
        cancel_rooms_operation(%{"operation_id" => "op-cancel-rooms-1", "room_ids" => ["room-b"]})

      original = apply_one!(build_conn(), operation)

      retry = apply_one!(build_conn(), operation)

      assert retry == original

      assert %{"status" => "active", "revision" => 3, "cash_paid_cents" => 9000} =
               group_data("group-81")

      assert %{"cash_refunded_cents" => 3000} = ledger()
    end
  end

  defp fund_credit_lot(group_id, amount_cents) do
    open_group!(build_conn(), %{"group_id" => group_id})

    apply_one!(
      build_conn(),
      record_cash_operation(%{"group_id" => group_id, "amount_cents" => amount_cents})
    )

    apply_one!(
      build_conn(),
      cancel_operation(%{
        "group_id" => group_id,
        "occurred_on" => "2026-11-26",
        "refund_method" => "hotel_credit"
      })
    )

    :ok
  end

  defp group_data(group_id) do
    assert %{status: 200} = conn = get_group(build_conn(), group_id)
    json_response(conn, 200)["data"]
  end

  defp ledger(on \\ nil) do
    assert %{status: 200} = conn = get_ledger(build_conn(), on)
    json_response(conn, 200)["data"]
  end

  defp guest_credit(guest_id, on \\ nil) do
    assert %{status: 200} = conn = get_guest_credit(build_conn(), guest_id, on)
    json_response(conn, 200)["data"]
  end

  defp payment_data(payment_operation_id) do
    assert %{status: 200} = conn = get_payment(build_conn(), payment_operation_id)
    json_response(conn, 200)["data"]
  end
end
