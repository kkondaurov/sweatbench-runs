defmodule GroupStayWeb.RoomAccountingTest do
  @moduledoc """
  Room-level accounting and the payment-correction operations delivered with
  this release: per-room deposit fields, cancel_rooms, reduce_cash_payment,
  charge_back_payment, payment reconciliation, credit entitlement clawbacks,
  and the unattributed funding that predates durable operation records.
  """

  use GroupStayWeb.ConnCase, async: true

  import GroupStay.TestOperations

  alias GroupStay.DurableOperations.OperationRecord
  alias GroupStay.Repo

  # group-81 defaults: flexible, booked 2026-10-03, arrival 2026-12-10 with
  # rooms room-a (15000/night) and room-b (17500/night) for 3 nights, so
  # room-a is due 9000 and room-b is due 10500 (group due 19500); the stay
  # is refundable through 2026-11-26.
  @refundable "2026-11-01"
  @non_refundable "2026-11-27"

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", batch(List.wrap(operations)))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_data(conn, path) do
    conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  defp room_view(group_data, room_id) do
    Enum.find(group_data["rooms"], &(&1["room_id"] == room_id))
  end

  ## Room-level accounting

  describe "room fields on the group response" do
    test "every room exposes status, deposit due, and its paid amounts", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 10000)])

      data = get_data(conn, "/api/v1/groups/group-81")

      # 10000 fills room-a's 9000 deposit first, then dips into room-b.
      assert room_view(data, "room-a") == %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 15000,
               "status" => "active",
               "deposit_due_cents" => 9000,
               "cash_paid_cents" => 9000,
               "credit_paid_cents" => 0
             }

      assert room_view(data, "room-b")["cash_paid_cents"] == 1000
      assert room_view(data, "room-b")["status"] == "active"
      assert room_view(data, "room-b")["deposit_due_cents"] == 10500
    end

    test "credit funding follows cash in the rooms' original order", %{conn: conn} do
      submit(conn, [
        open_group(),
        pay("group-81", 5000),
        cancel("group-81", "2026-10-20", %{
          "operation_id" => "op-lot",
          "refund_method" => "hotel_credit"
        })
      ])

      # A fresh group of the same guest absorbs the issued lot.
      submit(conn, [
        open_group(%{
          "operation_id" => "open-second",
          "group_id" => "group-second",
          "occurred_on" => "2026-10-25",
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-23",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 20000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 20000}
          ]
        }),
        apply_hotel_credit("group-second", 5500, %{"occurred_on" => "2026-10-26"})
      ])

      data = get_data(conn, "/api/v1/groups/group-second")

      # Deposits are 12000 per room; the 5500 lot fills room-a first.
      assert room_view(data, "room-a")["credit_paid_cents"] == 5500
      assert room_view(data, "room-b")["credit_paid_cents"] == 0
      assert room_view(data, "room-b")["cash_paid_cents"] == 0
    end
  end

  ## Settling selected rooms

  describe "cancel_rooms" do
    test "settles only the selected rooms and reports their ids in original order", %{conn: conn} do
      submit(conn, [
        open_group(%{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
            %{"room_id" => "room-c", "nightly_rate_cents" => 12500}
          ]
        }),
        pay("group-81", 10000)
      ])

      results =
        submit(conn, cancel_rooms("group-81", ["room-b", "room-a"], @refundable))

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "cancelled_room_ids" => ["room-a", "room-b"],
                 "refunded_cents" => 10000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = results

      data = get_data(conn, "/api/v1/groups/group-81")

      # Room-c was never touched: only its deposit remains due.
      assert data["status"] == "active"
      assert data["lodging_total_cents"] == 37500
      assert data["deposit_due_cents"] == 7500
      assert data["deposit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 7500
      assert room_view(data, "room-a")["status"] == "cancelled"
      assert room_view(data, "room-b")["status"] == "cancelled"
      assert room_view(data, "room-c")["status"] == "active"
    end

    test "leaves other rooms and their allocations unchanged", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 10000)])

      results = submit(conn, cancel_rooms("group-81", ["room-a"], @refundable))

      assert [
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-a"],
                 "refunded_cents" => 9000,
                 "revision" => 3
               }
             ] = results

      data = get_data(conn, "/api/v1/groups/group-81")

      # Only room-b's deposit remains due; its funding is untouched.
      assert data["status"] == "active"
      assert data["deposit_due_cents"] == 10500
      assert data["deposit_paid_cents"] == 1000
      assert data["outstanding_deposit_cents"] == 9500
      assert room_view(data, "room-a")["status"] == "cancelled"
      assert room_view(data, "room-b")["status"] == "active"
      assert room_view(data, "room-b")["cash_paid_cents"] == 1000

      assert get_data(conn, "/api/v1/ledger")["cash_held_cents"] == 1000
      assert get_data(conn, "/api/v1/ledger")["cash_refunded_cents"] == 9000
    end

    test "retains the selected rooms' cash for a non-refundable settlement", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 10000)])

      results = submit(conn, cancel_rooms("group-81", ["room-a"], @non_refundable))

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 9000}] =
               results

      assert get_data(conn, "/api/v1/ledger")["cash_retained_cents"] == 9000
    end

    test "rejects the complete operation with invalid_rooms", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 10000)])

      for bad_room_ids <- [
            ["room-a", "room-a"],
            ["room-a", "ghost-room"],
            [],
            "room-a"
          ] do
        assert [%{"status" => "rejected", "code" => "invalid_rooms"}] =
                 submit(conn, cancel_rooms("group-81", bad_room_ids, @refundable))
      end

      # A room already settled in an earlier cancel_rooms is no longer active.
      submit(
        conn,
        cancel_rooms("group-81", ["room-a"], @refundable, %{"operation_id" => "shrink-a"})
      )

      assert [%{"status" => "rejected", "code" => "invalid_rooms"}] =
               submit(
                 conn,
                 cancel_rooms("group-81", ["room-a"], @refundable, %{
                   "operation_id" => "shrink-again"
                 })
               )

      data = get_data(conn, "/api/v1/groups/group-81")
      assert data["revision"] == 3
      assert room_view(data, "room-b")["cash_paid_cents"] == 1000
    end

    test "computes the hotel-credit bonus once on the combined cash", %{conn: conn} do
      # room-a refundable cash is 9000 and room-b holds 1000: one lot on the
      # combined 10000, not two lots of 9900 and 1100.
      submit(conn, [open_group(), pay("group-81", 10000)])

      results =
        submit(
          conn,
          cancel_rooms("group-81", ["room-a", "room-b"], @refundable, %{
            "operation_id" => "cancel-shrink",
            "refund_method" => "hotel_credit"
          })
        )

      assert [%{"status" => "applied", "refunded_cents" => 0, "credit_issued_cents" => 11000}] =
               results

      assert get_data(conn, "/api/v1/guests/guest-22/credit")["lots"] == [
               %{
                 "source_operation_id" => "cancel-shrink",
                 "remaining_cents" => 11000,
                 "expires_on" => "2027-11-01"
               }
             ]

      assert get_data(conn, "/api/v1/ledger")["cash_converted_to_credit_cents"] == 10000
    end

    test "cancelling every active room cancels the group", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 19500)])

      results = submit(conn, cancel_rooms("group-81", ["room-a", "room-b"], @non_refundable))

      assert [%{"status" => "applied", "retained_cents" => 19500, "revision" => 3}] = results

      data = get_data(conn, "/api/v1/groups/group-81")

      assert data["status"] == "cancelled"
      assert data["deposit_due_cents"] == 0
      assert data["deposit_paid_cents"] == 0
    end

    test "hotel credit is refused for a non-refundable selection", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 10000)])

      results =
        submit(
          conn,
          cancel_rooms("group-81", ["room-a"], @non_refundable, %{
            "refund_method" => "hotel_credit"
          })
        )

      assert [%{"status" => "rejected", "code" => "refund_method_not_available"}] = results

      assert get_data(conn, "/api/v1/groups/group-81")["status"] == "active"
    end

    test "is durably idempotent", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 10000)])

      op = cancel_rooms("group-81", ["room-a"], @refundable, %{"operation_id" => "shrink-once"})

      [first] = submit(conn, [op])

      assert submit(conn, [op]) == [first]
      assert get_data(conn, "/api/v1/groups/group-81")["revision"] == 3
    end

    test "cancel_group settles the remaining active rooms", %{conn: conn} do
      submit(conn, [
        open_group(),
        pay("group-81", 10000),
        cancel_rooms("group-81", ["room-b"], @refundable)
      ])

      # room-a still holds 9000 of cash; room-b was settled with 1000.
      results = submit(conn, cancel("group-81", @refundable))

      assert [%{"status" => "applied", "refunded_cents" => 9000, "retained_cents" => 0}] =
               results

      assert get_data(conn, "/api/v1/ledger")["cash_refunded_cents"] == 10000
      assert get_data(conn, "/api/v1/groups/group-81")["status"] == "cancelled"
    end

    test "a refundable settlement restores the settled rooms' credit to its lot", %{conn: conn} do
      # pay-1's 10000 becomes a lot of 11000; it funds a new group's rooms.
      submit(conn, [
        open_group(),
        pay("group-81", 10000),
        cancel("group-81", @refundable, %{
          "operation_id" => "cancel-lot",
          "refund_method" => "hotel_credit"
        })
      ])

      submit(conn, [
        open_group(%{
          "operation_id" => "open-user",
          "group_id" => "group-user",
          "guest_id" => "guest-22",
          "occurred_on" => "2026-10-20",
          "arrival_on" => "2027-01-10",
          "departure_on" => "2027-01-13",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 25000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 25000}
          ]
        }),
        apply_hotel_credit("group-user", 11000, %{"operation_id" => "apply-lot"})
      ])

      # The credit fills room-a's 15000 deposit only; cancelling room-a
      # restores its 11000 to the lot, leaving room-b untouched.
      results = submit(conn, cancel_rooms("group-user", ["room-a"], @refundable))

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0}] = results

      data = get_data(conn, "/api/v1/groups/group-user")

      assert data["status"] == "active"
      assert data["deposit_due_cents"] == 15000
      assert data["credit_paid_cents"] == 0

      # The lot is whole again, with its original expiry.
      assert get_data(conn, "/api/v1/guests/guest-22/credit") == %{
               "guest_id" => "guest-22",
               "available_cents" => 11000,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-lot",
                   "remaining_cents" => 11000,
                   "expires_on" => "2027-11-01"
                 }
               ]
             }

      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 11000
    end

    test "a non-refundable settlement consumes the settled rooms' credit", %{conn: conn} do
      submit(conn, [
        open_group(),
        pay("group-81", 10000),
        cancel("group-81", @refundable, %{
          "operation_id" => "cancel-lot",
          "refund_method" => "hotel_credit"
        })
      ])

      submit(conn, [
        open_group(%{
          "operation_id" => "open-user",
          "group_id" => "group-user",
          "guest_id" => "guest-22",
          "occurred_on" => "2026-10-20",
          "arrival_on" => "2027-01-10",
          "departure_on" => "2027-01-13",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 25000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 25000}
          ]
        }),
        apply_hotel_credit("group-user", 11000, %{"operation_id" => "apply-lot"})
      ])

      # Within the non-refundable window for this group's 2027-01-10 arrival.
      results = submit(conn, cancel_rooms("group-user", ["room-a"], "2027-01-05"))

      assert [%{"status" => "applied", "retained_cents" => 0}] = results

      # The consumed credit leaves the liability permanently and nothing
      # returns to the lot; room-b keeps its own deposit untouched.
      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 0
      assert get_data(conn, "/api/v1/guests/guest-22/credit")["available_cents"] == 0
      assert get_data(conn, "/api/v1/groups/group-user")["deposit_due_cents"] == 15000
    end
  end

  ## Reducing recorded cash

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the deposit", %{conn: conn} do
      [_open, payment] =
        submit(conn, [open_group(), pay("group-81", 10000, %{"operation_id" => "pay-1"})])

      results = submit(conn, reduce_cash("pay-1", 4000))

      assert [
               %{
                 "payment_operation_id" => "pay-1",
                 "group_id" => "group-81",
                 "amount_cents" => 4000,
                 "outstanding_deposit_cents" => 13500,
                 "revision" => 3
               }
             ] = results

      data = get_data(conn, "/api/v1/groups/group-81")

      # Reverse fill order: room-b's 1000 leaves first, then 3000 of room-a's.
      assert room_view(data, "room-a")["cash_paid_cents"] == 6000
      assert room_view(data, "room-b")["cash_paid_cents"] == 0

      assert get_data(conn, "/api/v1/ledger")["cash_reduced_cents"] == 4000
      assert get_data(conn, "/api/v1/ledger")["cash_held_cents"] == 6000
    end

    test "successive reductions compose and the full remainder is valid", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 10000, %{"operation_id" => "pay-1"})])

      assert [%{"outstanding_deposit_cents" => 13500}] = submit(conn, reduce_cash("pay-1", 4000))
      assert [%{"outstanding_deposit_cents" => 19500}] = submit(conn, reduce_cash("pay-1", 6000))

      data = get_data(conn, "/api/v1/groups/group-81")
      assert data["cash_paid_cents"] == 0

      assert get_data(conn, "/api/v1/ledger")["cash_reduced_cents"] == 10000
    end

    test "reduces only the target payment's held cash", %{conn: conn} do
      submit(conn, [
        open_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        pay("group-81", 9500, %{"operation_id" => "pay-2"})
      ])

      submit(conn, reduce_cash("pay-1", 10000))

      data = get_data(conn, "/api/v1/groups/group-81")

      # pay-2's 9500 still funds room-b.
      assert room_view(data, "room-a")["cash_paid_cents"] == 0
      assert room_view(data, "room-b")["cash_paid_cents"] == 9500
      assert get_data(conn, "/api/v1/ledger")["cash_held_cents"] == 9500
    end

    test "rejection codes follow the documented rules", %{conn: conn} do
      submit(conn, [
        open_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        # Legacy funding: the same release accepts operations without a
        # durable operation identity.
        pay("group-81", 5000, %{"operation_id" => nil})
      ])

      # No durable operation record exists for the identifier at all.
      assert [%{"status" => "rejected", "code" => "operation_not_found"}] =
               submit(conn, reduce_cash("never-submitted", 100))

      # Legacy funding cannot be targeted either.
      assert [%{"status" => "rejected", "code" => "operation_not_found"}] =
               submit(conn, reduce_cash("pay-legacy", 100))

      # Non-positive reductions are invalid amounts.
      for bad <- [0, -500] do
        assert [%{"status" => "rejected", "code" => "invalid_amount"}] =
                 submit(conn, reduce_cash("pay-1", bad))
      end

      # A reduction beyond the held cash when a smaller one could succeed.
      assert [%{"status" => "rejected", "code" => "reduction_exceeds_held_cash"}] =
               submit(conn, reduce_cash("pay-1", 10001))

      # An applied payment with no held cash remaining is not reducible.
      submit(conn, reduce_cash("pay-1", 10000))

      assert [%{"status" => "rejected", "code" => "payment_not_reducible"}] =
               submit(conn, reduce_cash("pay-1", 100))

      # A rejected payment is not reducible.
      submit(conn, [pay("group-81", 999_999, %{"operation_id" => "pay-rejected"})])

      assert [%{"status" => "rejected", "code" => "payment_not_reducible"}] =
               submit(conn, reduce_cash("pay-rejected", 100))

      # Neither is a non-payment operation: the guest has no credit, so this
      # application is rejected — but its durable record still exists.
      submit(conn, [apply_hotel_credit("group-81", 100, %{"operation_id" => "credit-op"})])

      assert [%{"status" => "rejected", "code" => "payment_not_reducible"}] =
               submit(conn, reduce_cash("credit-op", 100))
    end

    test "the stored payment result is never rewritten", %{conn: conn} do
      [_open, payment] =
        submit(conn, [open_group(), pay("group-81", 10000, %{"operation_id" => "pay-1"})])

      submit(conn, reduce_cash("pay-1", 4000))

      # Retrying the original payment replays its exact original result
      # without reapplying cash, even though group state moved on.
      assert submit(conn, [pay("group-81", 10000, %{"operation_id" => "pay-1"})]) == [payment]

      data = get_data(conn, "/api/v1/groups/group-81")
      assert data["cash_paid_cents"] == 6000
      assert data["revision"] == 3
    end

    test "is durably idempotent and follows the revision contract", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 10000, %{"operation_id" => "pay-1"})])

      op = reduce_cash("pay-1", 4000, %{"operation_id" => "reduce-once"})
      [first] = submit(conn, [op])
      assert submit(conn, [op]) == [first]
      assert get_data(conn, "/api/v1/groups/group-81")["revision"] == 3

      stale =
        reduce_cash("pay-1", 1000, %{"operation_id" => "reduce-stale", "expected_revision" => 1})

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 3
               }
             ] = submit(conn, [stale])

      # The payment identifier must name a durably recorded operation before
      # any other validation result can be produced.
      assert [%{"status" => "rejected", "code" => "operation_not_found"}] =
               submit(conn, reduce_cash("never-submitted", 4000, %{"expected_revision" => 1}))
    end
  end

  ## Reconciling one payment

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reports the current disposition of every cent", %{conn: conn} do
      submit(conn, [
        open_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        reduce_cash("pay-1", 2000, %{"operation_id" => "reduce-1"})
      ])

      # 2000 reduced; 8000 still held.
      assert get_data(conn, "/api/v1/payments/pay-1") == %{
               "payment_operation_id" => "pay-1",
               "recorded_cents" => 10000,
               "held_cents" => 8000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 2000,
               "charged_back_cents" => 0
             }

      # A settled payment keeps a complete statement: retained cash moves to
      # charged-back on chargeback.
      submit(conn, [cancel("group-81", @non_refundable), charge_back("pay-1")])

      assert get_data(conn, "/api/v1/payments/pay-1") == %{
               "payment_operation_id" => "pay-1",
               "recorded_cents" => 10000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 2000,
               "charged_back_cents" => 8000
             }
    end

    test "reading never changes state", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 10000, %{"operation_id" => "pay-1"})])

      first = get_data(conn, "/api/v1/payments/pay-1")
      second = get_data(conn, "/api/v1/payments/pay-1")

      assert first == second
      assert first["held_cents"] == 10000
      assert get_data(conn, "/api/v1/groups/group-81")["revision"] == 2
    end

    test "all seven monetary fields are always present, including zero", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 100, %{"operation_id" => "pay-1"})])

      data = get_data(conn, "/api/v1/payments/pay-1")

      assert Map.keys(data) |> Enum.sort() == [
               "charged_back_cents",
               "converted_to_credit_cents",
               "held_cents",
               "payment_operation_id",
               "recorded_cents",
               "reduced_cents",
               "refunded_cents",
               "retained_cents"
             ]

      assert data["recorded_cents"] ==
               data["held_cents"] + data["refunded_cents"] + data["retained_cents"] +
                 data["converted_to_credit_cents"] + data["reduced_cents"] +
                 data["charged_back_cents"]
    end

    test "404 for unknown identifiers and legacy funding, 422 for non-cash operations", %{
      conn: conn
    } do
      conn = get(conn, "/api/v1/payments/never-submitted")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}

      submit(conn, [open_group(), pay("group-81", 1000, %{"operation_id" => nil})])

      conn = get(conn, "/api/v1/payments/pay-noid")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}

      submit(conn, [apply_hotel_credit("group-81", 100, %{"operation_id" => "credit-op"})])

      conn = get(conn, "/api/v1/payments/credit-op")
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}

      submit(conn, [pay("group-81", 999_999, %{"operation_id" => "rejected-op"})])

      conn = get(conn, "/api/v1/payments/rejected-op")
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end
  end

  ## Charging back a payment

  describe "charge_back_payment" do
    test "reverses held cash and reopens the outstanding deposit", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 10000, %{"operation_id" => "pay-1"})])

      results = submit(conn, charge_back("pay-1"))

      assert [
               %{
                 "payment_operation_id" => "pay-1",
                 "group_id" => "group-81",
                 "charged_back_cents" => 10000,
                 "outstanding_deposit_cents" => 19500,
                 "revision" => 3
               }
             ] = results

      data = get_data(conn, "/api/v1/groups/group-81")

      assert data["status"] == "active"
      assert data["cash_paid_cents"] == 0
      assert room_view(data, "room-a")["cash_paid_cents"] == 0
      assert room_view(data, "room-b")["cash_paid_cents"] == 0

      assert get_data(conn, "/api/v1/ledger")["cash_charged_back_cents"] == 10000
      assert get_data(conn, "/api/v1/ledger")["cash_held_cents"] == 0
    end

    test "works whether the group is active or cancelled and reclassifies history", %{conn: conn} do
      submit(conn, [
        open_group(),
        pay("group-81", 10000, %{"operation_id" => "pay-1"}),
        cancel("group-81", @refundable)
      ])

      results = submit(conn, charge_back("pay-1"))

      assert [
               %{
                 "group_id" => "group-81",
                 "charged_back_cents" => 10000,
                 "revision" => 4
               }
             ] = results

      # The historical refund moves to charged-back cash; the ledger
      # classification changes, the refund itself is not reissued.
      assert get_data(conn, "/api/v1/ledger")["cash_refunded_cents"] == 0
      assert get_data(conn, "/api/v1/ledger")["cash_charged_back_cents"] == 10000

      assert get_data(conn, "/api/v1/payments/pay-1") == %{
               "payment_operation_id" => "pay-1",
               "recorded_cents" => 10000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 10000
             }

      # A payment can be charged back only once.
      assert [%{"status" => "rejected", "code" => "payment_not_chargeable"}] =
               submit(conn, charge_back("pay-1", %{"operation_id" => "cb-second"}))
    end

    test "keeps its own idempotent record without rewriting the payment's", %{conn: conn} do
      [_open, payment] =
        submit(conn, [open_group(), pay("group-81", 10000, %{"operation_id" => "pay-1"})])

      op = charge_back("pay-1", %{"operation_id" => "cb-once"})
      [first] = submit(conn, [op])

      assert submit(conn, [op]) == [first]
      assert submit(conn, [pay("group-81", 10000, %{"operation_id" => "pay-1"})]) == [payment]

      assert get_data(conn, "/api/v1/ledger")["cash_charged_back_cents"] == 10000
    end

    test "rejection codes follow the documented rules", %{conn: conn} do
      submit(conn, [
        open_group(),
        pay("group-81", 1000, %{"operation_id" => "pay-1"}),
        apply_hotel_credit("group-81", 100, %{"operation_id" => "credit-op"}),
        pay("group-81", 999_999, %{"operation_id" => "pay-rejected"})
      ])

      assert [%{"status" => "rejected", "code" => "operation_not_found"}] =
               submit(conn, charge_back("never-submitted"))

      # A non-payment operation, a rejected payment.
      assert [%{"status" => "rejected", "code" => "payment_not_chargeable"}] =
               submit(conn, charge_back("credit-op"))

      assert [%{"status" => "rejected", "code" => "payment_not_chargeable"}] =
               submit(conn, charge_back("pay-rejected"))

      # A payment fully recorded as reduced cannot be charged back.
      submit(conn, reduce_cash("pay-1", 1000, %{"operation_id" => "reduce-all"}))

      assert [%{"status" => "rejected", "code" => "payment_not_chargeable"}] =
               submit(conn, charge_back("pay-1"))
    end

    test "a chargeback increments only the original payment group's revision", %{conn: conn} do
      submit(conn, [
        open_group(),
        pay("group-81", 19500, %{"operation_id" => "pay-1"}),
        cancel("group-81", @refundable, %{
          "operation_id" => "cancel-lot",
          "refund_method" => "hotel_credit"
        }),
        open_group(%{
          "operation_id" => "open-target",
          "group_id" => "group-target",
          "occurred_on" => "2026-10-20",
          "arrival_on" => "2027-01-10",
          "departure_on" => "2027-01-13",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 80000}]
        }),
        apply_hotel_credit("group-target", 21450, %{"operation_id" => "apply-lot"})
      ])

      submit(conn, charge_back("pay-1"))

      # The funded group's state and revision are untouched.
      assert get_data(conn, "/api/v1/groups/group-target")["revision"] == 2
      assert get_data(conn, "/api/v1/groups/group-target")["credit_paid_cents"] == 21450
      assert get_data(conn, "/api/v1/groups/group-81")["revision"] == 4
    end
  end

  ## Credit entitlements and shortfalls

  describe "chargeback clawbacks of converted cash" do
    test "entitlements telescope across payments in fill order", %{conn: conn} do
      # One room due 10000; pay-1 funds 6000, pay-2 the remaining 4000. The
      # refundable hotel-credit settlement issues one lot of 11000.
      submit(conn, [
        open_group(%{
          "operation_id" => "open-single",
          "group_id" => "group-single",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25000}]
        }),
        pay("group-single", 6000, %{"operation_id" => "pay-1"}),
        pay("group-single", 4000, %{"operation_id" => "pay-2"}),
        cancel("group-single", @refundable, %{
          "operation_id" => "cancel-lot",
          "refund_method" => "hotel_credit"
        })
      ])

      # Claims telescope exactly to the issued lot: 6600 to pay-1, 4400 to
      # pay-2.
      submit(conn, charge_back("pay-1"))

      # pay-1's claim leaves the lot's remaining balance.
      assert get_data(conn, "/api/v1/guests/guest-22/credit")["available_cents"] == 4400

      submit(conn, charge_back("pay-2"))

      assert get_data(conn, "/api/v1/guests/guest-22/credit")["available_cents"] == 0
      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 0
    end

    test "the unattributed senior block advances the running total without claiming", %{
      conn: conn
    } do
      # Legacy cash of 10000 funds room-a first; recorded pay-1 tops up.
      submit(conn, [
        open_group(),
        pay("group-81", 10000, %{"operation_id" => nil}),
        pay("group-81", 9500, %{"operation_id" => "pay-1"}),
        cancel("group-81", @refundable, %{
          "operation_id" => "cancel-lot",
          "refund_method" => "hotel_credit"
        })
      ])

      # Lot 21450: the legacy block advances the running issued value to
      # 11000, so pay-1's claim is the remaining 10450.
      submit(conn, charge_back("pay-1"))

      assert get_data(conn, "/api/v1/guests/guest-22/credit")["available_cents"] == 11000
      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 11000
    end

    test "rounding applies half-up to the running totals", %{conn: conn} do
      submit(conn, [
        open_group(%{
          "operation_id" => "open-tiny",
          "group_id" => "group-tiny",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 1250}]
        }),
        pay("group-tiny", 250, %{"operation_id" => "pay-t1"}),
        pay("group-tiny", 250, %{"operation_id" => "pay-t2"}),
        cancel("group-tiny", @refundable, %{
          "operation_id" => "cancel-tiny",
          "refund_method" => "hotel_credit"
        })
      ])

      # Cash 500: issued value through t1 = 275, through t2 = 550. Claims:
      # 275 and 275.
      submit(conn, charge_back("pay-t1"))
      assert get_data(conn, "/api/v1/guests/guest-22/credit")["available_cents"] == 275

      submit(conn, charge_back("pay-t2"))
      assert get_data(conn, "/api/v1/guests/guest-22/credit")["available_cents"] == 0
    end

    test "a clawback that cannot be removed becomes the lot's shortfall", %{conn: conn} do
      # pay-1's 10000 converts into a lot of 11000 on a refundable settlement.
      submit(conn, [
        open_group(%{
          "operation_id" => "open-src",
          "group_id" => "group-src",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25000}]
        }),
        pay("group-src", 10000, %{"operation_id" => "pay-1"}),
        cancel("group-src", @refundable, %{
          "operation_id" => "cancel-src",
          "refund_method" => "hotel_credit"
        })
      ])

      # The full lot funds another active group of the same guest.
      submit(conn, [
        open_group(%{
          "operation_id" => "open-user",
          "group_id" => "group-user",
          "guest_id" => "guest-22",
          "occurred_on" => "2026-10-20",
          "arrival_on" => "2027-01-10",
          "departure_on" => "2027-01-14",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 40000}]
        }),
        apply_hotel_credit("group-user", 11000, %{"operation_id" => "apply-lot"})
      ])

      # Charging pay-1 back claws at the lot's credit already applied; the
      # lot's remaining balance is zero, so the whole 11000 entitlement is
      # unrecovered and covered by the applied credit as a shortfall.
      assert [%{"status" => "applied", "charged_back_cents" => 10000}] =
               submit(conn, charge_back("pay-1"))

      assert get_data(conn, "/api/v1/ledger")["credit_shortfall_cents"] == 11000

      # The liability keeps including credit covered by the shortfall.
      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 11000
      assert get_data(conn, "/api/v1/groups/group-user")["revision"] == 2

      # Non-refundable settlement consumes the credit: the shortfall and the
      # liability drop together.
      submit(conn, [cancel("group-user", "2027-01-05")])

      assert get_data(conn, "/api/v1/ledger")["credit_shortfall_cents"] == 0
      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 0
    end

    test "credit returning to a shortfalled lot extinguishes the clawback first", %{conn: conn} do
      submit(conn, [
        open_group(%{
          "operation_id" => "open-src2",
          "group_id" => "group-src2",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25000}]
        }),
        pay("group-src2", 10000, %{"operation_id" => "pay-1"}),
        cancel("group-src2", @refundable, %{
          "operation_id" => "cancel-src2",
          "refund_method" => "hotel_credit"
        })
      ])

      submit(conn, [
        open_group(%{
          "operation_id" => "open-user2",
          "group_id" => "group-user2",
          "guest_id" => "guest-22",
          "occurred_on" => "2026-10-20",
          "arrival_on" => "2027-01-10",
          "departure_on" => "2027-01-14",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 40000}]
        }),
        apply_hotel_credit("group-user2", 11000, %{"operation_id" => "apply-lot2"})
      ])

      assert [%{"status" => "applied"}] = submit(conn, charge_back("pay-1"))
      assert get_data(conn, "/api/v1/ledger")["credit_shortfall_cents"] == 11000

      # A refundable settlement restores the applied credit to the lot; the
      # unrecovered clawback absorbs the entire return and nothing becomes
      # available.
      submit(conn, cancel("group-user2", "2026-11-15"))

      assert get_data(conn, "/api/v1/guests/guest-22/credit")["available_cents"] == 0
      assert get_data(conn, "/api/v1/ledger")["credit_shortfall_cents"] == 0
      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 0
    end
  end

  ## Unattributed funding

  describe "funding without a durable operation record" do
    test "fills the rooms in order ahead of recorded funding and cannot be targeted", %{
      conn: conn
    } do
      submit(conn, [
        open_group(),
        pay("group-81", 10000, %{"operation_id" => nil}),
        pay("group-81", 9500, %{"operation_id" => "pay-1"})
      ])

      data = get_data(conn, "/api/v1/groups/group-81")

      # The senior block fills room-a fully and room-b partially; the
      # recorded payment completes room-b.
      assert room_view(data, "room-a")["cash_paid_cents"] == 9000
      assert room_view(data, "room-b")["cash_paid_cents"] == 10500

      # Legacy funding has no payment identifier, so reconciliation cannot
      # reach it and a reduction has nothing to address.
      assert json_response(get(conn, "/api/v1/payments/legacy-id"), 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      assert [%{"status" => "rejected", "code" => "operation_not_found"}] =
               submit(conn, reduce_cash("pay-legacy", 100))

      # The recorded payment reduces normally.
      assert [%{"status" => "applied", "amount_cents" => 9500}] =
               submit(conn, reduce_cash("pay-1", 9500))
    end
  end
end
