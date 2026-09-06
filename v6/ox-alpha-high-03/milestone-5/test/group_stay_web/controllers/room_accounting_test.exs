defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: true

  @moduletag :capture_log

  # Default rooms over three nights: room-a lodges 45_000 (deposit 9_000) and
  # room-b lodges 52_500 (deposit 10_500); the group requires 19_500.
  @deposit_a 9_000
  @deposit_b 10_500

  describe "room-level accounting in group reads" do
    test "rooms expose status, deposit due, cash paid, and credit paid" do
      open_default_group("group-rooms-read")

      assert fetch_group("group-rooms-read")["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => @deposit_a,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "status" => "active",
                 "deposit_due_cents" => @deposit_b,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]
    end

    test "cash and credit fund active rooms in original order, one room at a time" do
      fund_guest_credit(11_000)
      open_default_group("group-fill")

      run_and_get_results([
        pay_operation("group-fill", 9_500, %{"operation_id" => "op-pay-fill"}),
        credit_operation("group-fill", 10_000, %{
          "operation_id" => "op-credit-fill",
          "occurred_on" => "2026-12-01"
        })
      ])

      [a, b] = fetch_group("group-fill")["rooms"]
      assert a["cash_paid_cents"] == @deposit_a
      assert a["credit_paid_cents"] == 0

      assert b["cash_paid_cents"] == 500
      assert b["credit_paid_cents"] == 10_000

      group = fetch_group("group-fill")
      assert group["deposit_due_cents"] == @deposit_a + @deposit_b
      assert group["cash_paid_cents"] == 9_500
      assert group["credit_paid_cents"] == 10_000
      assert group["deposit_paid_cents"] == 19_500
      assert group["outstanding_deposit_cents"] == 0
    end

    test "new funding operations allocate after earlier ones in processing order" do
      open_default_group("group-sequence")

      run_and_get_results([
        pay_operation("group-sequence", 4_000, %{"operation_id" => "op-first"})
      ])

      run_and_get_results([
        pay_operation("group-sequence", 6_000, %{"operation_id" => "op-second"})
      ])

      assert [_a, b] = fetch_group("group-sequence")["rooms"]
      assert b["cash_paid_cents"] == 1_000

      assert fetch_payment("op-first")["held_cents"] == 4_000
      assert fetch_payment("op-second")["held_cents"] == 6_000
      assert fetch_group("group-sequence")["outstanding_deposit_cents"] == 9_500
    end

    test "totals describe active rooms only once a room is settled" do
      open_default_group("group-active-totals")
      run_and_get_results([pay_operation("group-active-totals", 19_500)])

      run_and_get_results([
        cancel_rooms_operation("group-active-totals", ["room-a"], %{
          "occurred_on" => "2026-11-26"
        })
      ])

      group = fetch_group("group-active-totals")

      assert group["lodging_total_cents"] == 52_500
      assert group["deposit_due_cents"] == @deposit_b
      assert group["deposit_paid_cents"] == @deposit_b
      assert group["outstanding_deposit_cents"] == 0
      assert group["status"] == "active"

      assert group["rooms"] |> Enum.find(&(&1["room_id"] == "room-a")) |> Map.fetch!("status") ==
               "cancelled"
    end
  end

  describe "cancel_rooms" do
    test "settles selected rooms with the same rules as full cancellation" do
      open_default_group("group-cancel-rooms")

      results =
        run_and_get_results([
          pay_operation("group-cancel-rooms", 19_500),
          cancel_rooms_operation("group-cancel-rooms", ["room-b", "room-a"], %{
            "occurred_on" => "2026-11-26",
            "operation_id" => "op-drop-two"
          })
        ])

      assert List.last(results) == %{
               "operation_id" => "op-drop-two",
               "status" => "applied",
               "group_id" => "group-cancel-rooms",
               "cancelled_room_ids" => ["room-a", "room-b"],
               "refunded_cents" => 19_500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
    end

    test "leaves other rooms and their allocations untouched" do
      open_default_group("group-partial")
      run_and_get_results([pay_operation("group-partial", 12_000)])

      run_and_get_results([
        cancel_rooms_operation("group-partial", ["room-b"], %{"occurred_on" => "2026-11-26"})
      ])

      [a, b] = fetch_group("group-partial")["rooms"]

      assert a["cash_paid_cents"] == @deposit_a
      assert a["status"] == "active"

      # Room-b held the remaining 3_000 of the payment; it settles as a refund.
      assert b["status"] == "cancelled"
      assert b["cash_paid_cents"] == 0
      assert b["deposit_due_cents"] == 0

      assert fetch_ledger()["cash_refunded_cents"] == 3_000
      assert fetch_ledger()["cash_held_cents"] == @deposit_a
    end

    test "issues the hotel-credit bonus once on the combined cash of the selected rooms" do
      open_default_group("group-room-credit")
      run_and_get_results([pay_operation("group-room-credit", 19_500)])

      results =
        run_and_get_results([
          cancel_rooms_operation("group-room-credit", ["room-a", "room-b"], %{
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit",
            "operation_id" => "cancel-rooms-credit"
          })
        ])

      # 19_500 * 110% = 21_450: one bonus over the combined amount.
      assert hd(results)["credit_issued_cents"] == 21_450
      assert hd(results)["refunded_cents"] == 0
      assert hd(results)["retained_cents"] == 0

      credit = fetch_credit("guest-22")

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "cancel-rooms-credit",
                 "remaining_cents" => 21_450,
                 "expires_on" => "2027-11-27"
               }
             ]
    end

    test "retains cash when the selected rooms settle non-refundably" do
      open_default_group("group-late-rooms")
      run_and_get_results([pay_operation("group-late-rooms", 19_500)])

      results =
        run_and_get_results([
          cancel_rooms_operation("group-late-rooms", ["room-a"], %{"occurred_on" => "2026-12-05"})
        ])

      assert hd(results)["retained_cents"] == @deposit_a
      assert hd(results)["refunded_cents"] == 0
      assert fetch_ledger()["cash_retained_cents"] == @deposit_a
    end

    test "cancels the group when no active rooms remain" do
      open_default_group("group-last-rooms")
      run_and_get_results([pay_operation("group-last-rooms", 19_500)])

      results =
        run_and_get_results([
          cancel_rooms_operation("group-last-rooms", ["room-b"], %{"occurred_on" => "2026-11-26"}),
          cancel_rooms_operation("group-last-rooms", ["room-a"], %{
            "occurred_on" => "2026-11-26",
            "operation_id" => "op-drop-last"
          })
        ])

      assert List.last(results)["cancelled_room_ids"] == ["room-a"]
      assert fetch_group("group-last-rooms")["status"] == "cancelled"

      assert fetch_group("group-last-rooms")["outstanding_deposit_cents"] == 0
      assert fetch_group("group-last-rooms")["deposit_due_cents"] == 0

      later =
        run_and_get_results([
          pay_operation("group-last-rooms", 100, %{"operation_id" => "op-after-rooms"})
        ])

      assert hd(later)["code"] == "group_not_active"
    end

    test "cancel_group settles only the remaining active rooms" do
      open_default_group("group-mixed-cancel")
      run_and_get_results([pay_operation("group-mixed-cancel", 12_000)])

      run_and_get_results([
        cancel_rooms_operation("group-mixed-cancel", ["room-b"], %{"occurred_on" => "2026-11-26"})
      ])

      results =
        run_and_get_results([
          cancel_operation("group-mixed-cancel", %{
            "occurred_on" => "2026-11-26",
            "operation_id" => "op-final-cancel"
          })
        ])

      assert hd(results) == %{
               "operation_id" => "op-final-cancel",
               "status" => "applied",
               "group_id" => "group-mixed-cancel",
               "refunded_cents" => @deposit_a,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      assert fetch_ledger()["cash_refunded_cents"] == @deposit_a + 3_000
    end

    test "rejects anything but distinct active rooms of the group" do
      open_default_group("group-invalid-rooms")

      run_and_get_results([
        pay_operation("group-invalid-rooms", 1_000),
        cancel_rooms_operation("group-invalid-rooms", ["room-a"], %{
          "occurred_on" => "2026-11-26",
          "operation_id" => "op-drop-a"
        })
      ])

      cases = [
        duplicates: ["room-a", "room-a"],
        unknown_room: ["nope"],
        cancelled_room: ["room-a"],
        empty: []
      ]

      for {name, room_ids} <- cases do
        results =
          run_and_get_results([
            cancel_rooms_operation("group-invalid-rooms", room_ids, %{
              "occurred_on" => "2026-11-26",
              "operation_id" => "op-bad-#{name}"
            })
          ])

        assert hd(results)["code"] == "invalid_rooms", "expected invalid_rooms for #{name}"
      end

      assert fetch_group("group-invalid-rooms")["revision"] == 3
    end

    test "checks the revision before domain rules and is durably idempotent" do
      open_default_group("group-rev-rooms")

      stale =
        run_and_get_results([
          cancel_rooms_operation("group-rev-rooms", ["room-a"], %{
            "operation_id" => "op-stale-rooms",
            "expected_revision" => 9,
            "occurred_on" => "2026-11-26"
          })
        ])

      assert hd(stale)["code"] == "stale_revision"
      assert fetch_group("group-rev-rooms")["revision"] == 1

      operation =
        cancel_rooms_operation("group-rev-rooms", ["room-a"], %{
          "occurred_on" => "2026-11-26",
          "expected_revision" => 1
        })

      first = run_and_get_results([operation])
      assert hd(first)["status"] == "applied"

      replay = run_and_get_results([operation])
      assert replay == first
      assert fetch_group("group-rev-rooms")["revision"] == 2
    end
  end

  defp run_and_get_results(operations) do
    post_operations(operations) |> json_response(200) |> Map.fetch!("results")
  end

  # Funds guest-22 with hotel credit by cancelling a flexible source group with
  # the hotel_credit refund method.
  defp fund_guest_credit(amount_cents) do
    # A flexible room deposits 20% of its lodging, rounded per room.
    nightly_rate_cents = amount_cents * 5
    lodging_cents = nightly_rate_cents * 3
    deposit_cents = div(lodging_cents * 20 + 50, 100)

    post_operations([
      open_operation(%{
        "operation_id" => "op-open-source",
        "group_id" => "group-credit-source",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-04",
        "rooms" => [%{"room_id" => "room-source", "nightly_rate_cents" => nightly_rate_cents}]
      }),
      pay_operation("group-credit-source", deposit_cents, %{"operation_id" => "op-pay-source"}),
      cancel_operation("group-credit-source", %{
        "occurred_on" => "2026-11-01",
        "refund_method" => "hotel_credit",
        "operation_id" => "cancel-source"
      })
    ])

    :ok
  end
end
