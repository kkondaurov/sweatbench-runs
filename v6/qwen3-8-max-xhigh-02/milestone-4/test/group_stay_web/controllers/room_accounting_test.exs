defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Groups.{CashPayment, Group, Room, RoomAllocation}
  alias GroupStay.Repo

  import Ecto.Query

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

  # Two rooms for three nights: room-a lodging 45000 deposit 9000, room-b
  # lodging 52500 deposit 10500. Flex-14 refundable through 2026-11-26.
  defp open_group_op(overrides) do
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
  end

  defp open_group(conn, overrides \\ %{}) do
    result = single_result(conn, [open_group_op(overrides)])
    assert result["status"] == "applied"
    result
  end

  defp pay_op(overrides) do
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
  end

  defp pay(conn, overrides \\ %{}) do
    result = single_result(conn, [pay_op(overrides)])
    assert result["status"] == "applied"
    result
  end

  defp cancel_rooms_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      overrides
    )
  end

  defp cancel_rooms(conn, overrides \\ %{}) do
    result = single_result(conn, [cancel_rooms_op(overrides)])
    assert result["status"] == "applied"
    result
  end

  defp cancel_group_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp apply_credit_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 1100
      },
      overrides
    )
  end

  defp get_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_credit(conn, guest_id) do
    conn |> get("/api/v1/guests/#{guest_id}/credit") |> json_response(200) |> Map.fetch!("data")
  end

  defp room_by_id(group, room_id) do
    Enum.find(group["rooms"], &(&1["room_id"] == room_id))
  end

  # Issues a 1100-cent lot for guest-22 expiring 2027-10-04.
  defp issue_credit(conn) do
    open_group(conn, %{"operation_id" => "op-open-source", "group_id" => "group-source"})

    pay(conn, %{
      "operation_id" => "op-pay-source",
      "group_id" => "group-source",
      "amount_cents" => 1000
    })

    result =
      single_result(conn, [
        %{
          "operation_id" => "op-cancel-source",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-source",
          "refund_method" => "hotel_credit"
        }
      ])

    assert result["status"] == "applied"
    assert result["credit_issued_cents"] == 1100
  end

  describe "room-level accounting" do
    test "exposes each room's status, deposit, and funding", %{conn: conn} do
      open_group(conn)
      pay(conn, %{"amount_cents" => 12000})

      group = get_group(conn, "group-81")

      assert room_by_id(group, "room-a") == %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 15000,
               "status" => "active",
               "deposit_due_cents" => 9000,
               "cash_paid_cents" => 9000,
               "credit_paid_cents" => 0
             }

      assert room_by_id(group, "room-b") == %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 17500,
               "status" => "active",
               "deposit_due_cents" => 10500,
               "cash_paid_cents" => 3000,
               "credit_paid_cents" => 0
             }
    end

    test "cash and credit fund active rooms in their original order", %{conn: conn} do
      issue_credit(conn)
      open_group(conn)

      # Cash fills room-a's deposit before moving to room-b.
      pay(conn, %{"operation_id" => "op-pay-1", "amount_cents" => 5000})
      pay(conn, %{"operation_id" => "op-pay-2", "amount_cents" => 6000})

      group = get_group(conn, "group-81")
      assert room_by_id(group, "room-a")["cash_paid_cents"] == 9000
      assert room_by_id(group, "room-b")["cash_paid_cents"] == 2000

      # Credit continues in operation-processing order where cash stopped.
      assert single_result(conn, [apply_credit_op(%{"amount_cents" => 1100})])["status"] ==
               "applied"

      group = get_group(conn, "group-81")
      assert room_by_id(group, "room-a")["credit_paid_cents"] == 0
      assert room_by_id(group, "room-b")["credit_paid_cents"] == 1100

      # Room funding agrees with the group totals.
      assert group["deposit_paid_cents"] == 12100
      assert group["cash_paid_cents"] == 11000
      assert group["credit_paid_cents"] == 1100
      assert group["outstanding_deposit_cents"] == 7400
    end

    test "a payment spanning rooms is held across them", %{conn: conn} do
      open_group(conn)
      pay(conn, %{"amount_cents" => 13000})

      group = get_group(conn, "group-81")
      assert room_by_id(group, "room-a")["cash_paid_cents"] == 9000
      assert room_by_id(group, "room-b")["cash_paid_cents"] == 4000
    end
  end

  describe "cancel_rooms" do
    test "settles only the selected rooms' allocated cash and credit", %{conn: conn} do
      issue_credit(conn)
      open_group(conn)
      pay(conn, %{"operation_id" => "op-pay-1", "amount_cents" => 13000})

      assert single_result(conn, [apply_credit_op(%{"amount_cents" => 1100})])["status"] ==
               "applied"

      result = cancel_rooms(conn, %{"room_ids" => ["room-b"]})

      assert result == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 4000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      group = get_group(conn, "group-81")
      assert group["status"] == "active"

      # The settled room keeps its accounting and drops out of the totals.
      assert room_by_id(group, "room-b")["status"] == "cancelled"
      assert room_by_id(group, "room-b")["deposit_due_cents"] == 10500

      # The other room and its allocations are unchanged.
      assert room_by_id(group, "room-a") == %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 15000,
               "status" => "active",
               "deposit_due_cents" => 9000,
               "cash_paid_cents" => 9000,
               "credit_paid_cents" => 0
             }

      # Totals describe active rooms only; the unpaid deposit for room-b
      # ceased to be due.
      assert group["lodging_total_cents"] == 45000
      assert group["deposit_due_cents"] == 9000
      assert group["deposit_paid_cents"] == 9000
      assert group["outstanding_deposit_cents"] == 0

      # The applied credit from room-b returned to its lot.
      assert get_credit(conn, "guest-22")["available_cents"] == 1100

      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 9000
      assert ledger["cash_refunded_cents"] == 4000
      assert ledger["credit_liability_cents"] == 1100
    end

    test "returns cancelled_room_ids in the group's original room order", %{conn: conn} do
      open_group(conn)

      result = cancel_rooms(conn, %{"room_ids" => ["room-b", "room-a"]})
      assert result["cancelled_room_ids"] == ["room-a", "room-b"]
      assert get_group(conn, "group-81")["status"] == "cancelled"
    end

    test "the group becomes cancelled when no active rooms remain", %{conn: conn} do
      open_group(conn)
      pay(conn, %{"amount_cents" => 13000})

      result = cancel_rooms(conn, %{"room_ids" => ["room-a", "room-b"]})
      assert result["refunded_cents"] == 13000
      assert result["revision"] == 3

      group = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["deposit_due_cents"] == 0
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0

      # A later operation sees the cancelled group.
      result = single_result(conn, [pay_op(%{"operation_id" => "op-pay-late"})])
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"
    end

    test "retains cash for a non-refundable settlement", %{conn: conn} do
      open_group(conn)
      pay(conn, %{"amount_cents" => 13000})

      result =
        cancel_rooms(conn, %{"room_ids" => ["room-b"], "occurred_on" => "2026-11-27"})

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 4000
      assert result["credit_issued_cents"] == 0

      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 9000
      assert ledger["cash_retained_cents"] == 4000
    end

    test "computes the hotel-credit bonus once on the combined cash amount", %{conn: conn} do
      # Two one-night rooms at 5015: each deposit is exactly 1003.
      open_group(conn, %{
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 5015},
          %{"room_id" => "room-b", "nightly_rate_cents" => 5015}
        ]
      })

      pay(conn, %{"operation_id" => "op-pay-1", "amount_cents" => 1003})
      pay(conn, %{"operation_id" => "op-pay-2", "amount_cents" => 1003})

      # Combined 2006: bonus rounds 200.6 up to 201, issuing 2207. Issuing
      # per room would round 100.3 down twice and issue 2208.
      result =
        cancel_rooms(conn, %{
          "room_ids" => ["room-a", "room-b"],
          "refund_method" => "hotel_credit"
        })

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 2207

      assert get_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 2207,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-rooms",
                   "remaining_cents" => 2207,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      assert get_ledger(conn)["cash_converted_to_credit_cents"] == 2006
    end

    test "hotel credit is rejected for a non-refundable settlement", %{conn: conn} do
      open_group(conn)
      pay(conn)

      result =
        single_result(conn, [
          cancel_rooms_op(%{
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit"
          })
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"

      group = get_group(conn, "group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2
      assert room_by_id(group, "room-a")["status"] == "active"
    end

    test "restores applied credit on a refundable settlement", %{conn: conn} do
      issue_credit(conn)
      open_group(conn)
      pay(conn, %{"amount_cents" => 18400})

      assert single_result(conn, [apply_credit_op(%{"amount_cents" => 1100})])["status"] ==
               "applied"

      # room-b holds 9400 cash and 1100 credit.
      result = cancel_rooms(conn, %{"room_ids" => ["room-b"]})
      assert result["refunded_cents"] == 9400

      assert get_credit(conn, "guest-22")["available_cents"] == 1100
      assert get_ledger(conn)["credit_liability_cents"] == 1100
    end

    test "consumes applied credit on a non-refundable settlement", %{conn: conn} do
      issue_credit(conn)
      open_group(conn)
      pay(conn, %{"amount_cents" => 18400})

      assert single_result(conn, [apply_credit_op(%{"amount_cents" => 1100})])["status"] ==
               "applied"

      result = cancel_rooms(conn, %{"room_ids" => ["room-b"], "occurred_on" => "2026-11-27"})
      assert result["retained_cents"] == 9400

      assert get_credit(conn, "guest-22")["available_cents"] == 0
      assert get_ledger(conn)["credit_liability_cents"] == 0
    end

    test "a later cancel_group settles only the remaining active rooms", %{conn: conn} do
      open_group(conn)
      pay(conn, %{"amount_cents" => 13000})

      assert cancel_rooms(conn, %{"room_ids" => ["room-a"]})["refunded_cents"] == 9000

      result = single_result(conn, [cancel_group_op(%{"operation_id" => "op-cancel"})])

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 4000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      group = get_group(conn, "group-81")
      assert group["status"] == "cancelled"

      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 13000
    end

    test "unpaid deposit for settled rooms reopens for later funding", %{conn: conn} do
      open_group(conn)
      pay(conn, %{"amount_cents" => 5000})

      assert cancel_rooms(conn, %{"room_ids" => ["room-a"]})["refunded_cents"] == 5000

      group = get_group(conn, "group-81")
      assert group["deposit_due_cents"] == 10500
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 10500

      # The remaining room can still be funded up to its deposit.
      result = pay(conn, %{"operation_id" => "op-pay-2", "amount_cents" => 10500})
      assert result["outstanding_deposit_cents"] == 0
      assert room_by_id(get_group(conn, "group-81"), "room-b")["cash_paid_cents"] == 10500

      result = single_result(conn, [pay_op(%{"operation_id" => "op-pay-3", "amount_cents" => 1})])
      assert result["status"] == "rejected"
      assert result["code"] == "payment_exceeds_outstanding"
    end

    test "reductions and chargebacks compose with room settlements", %{conn: conn} do
      open_group(conn)
      pay(conn, %{"amount_cents" => 13000})

      # room-b's 4000 is retained; the payment's held cash is the 9000 on
      # room-a.
      assert cancel_rooms(conn, %{
               "room_ids" => ["room-b"],
               "occurred_on" => "2026-11-27"
             })["retained_cents"] == 4000

      result =
        single_result(conn, [
          %{
            "operation_id" => "op-reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 9000
          }
        ])

      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 9000

      group = get_group(conn, "group-81")
      assert room_by_id(group, "room-a")["cash_paid_cents"] == 0
      assert group["deposit_paid_cents"] == 0
      assert room_by_id(group, "room-b")["cash_paid_cents"] == 4000

      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_retained_cents"] == 4000
      assert ledger["cash_reduced_cents"] == 9000
    end

    test "rejects room selections that cannot be used", %{conn: conn} do
      open_group(conn)
      pay(conn)

      variants = [
        %{"room_ids" => ["room-z"]},
        %{"room_ids" => ["room-a", "room-a"]},
        %{"room_ids" => []},
        %{"room_ids" => ["room-a", 42]},
        %{"room_ids" => [nil]}
      ]

      for {overrides, index} <- Enum.with_index(variants) do
        result =
          single_result(conn, [
            cancel_rooms_op(Map.merge(overrides, %{"operation_id" => "op-bad-#{index}"}))
          ])

        assert result["status"] == "rejected", "expected rejection for #{inspect(overrides)}"
        assert result["code"] == "invalid_rooms", "unexpected code for #{inspect(overrides)}"
      end

      # A room that is already cancelled cannot be settled again.
      assert cancel_rooms(conn, %{"room_ids" => ["room-a"]})["status"] == "applied"

      result = single_result(conn, [cancel_rooms_op(%{"operation_id" => "op-again"})])
      assert result["status"] == "rejected"
      assert result["code"] == "invalid_rooms"

      # A room identifier from another group does not identify a room here.
      open_group(conn, %{
        "operation_id" => "op-open-2",
        "group_id" => "group-82",
        "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 9000}]
      })

      result =
        single_result(conn, [
          cancel_rooms_op(%{
            "operation_id" => "op-other",
            "room_ids" => ["room-a"],
            "group_id" => "group-82"
          })
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_rooms"

      # The complete operation was rejected every time.
      group = get_group(conn, "group-81")
      assert group["revision"] == 3
      assert room_by_id(group, "room-b")["status"] == "active"
    end

    test "rejects a malformed room list as an invalid operation", %{conn: conn} do
      open_group(conn)

      for {overrides, index} <-
            Enum.with_index([
              %{"room_ids" => "room-a"},
              Map.delete(cancel_rooms_op(%{}), "room_ids")
            ]) do
        op = Map.put(overrides, "operation_id", "op-malformed-#{index}")
        [result] = results(submit(conn, [op]))
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end

      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "rejects a missing group and an inactive group", %{conn: conn} do
      result = single_result(conn, [cancel_rooms_op(%{"group_id" => "nope"})])
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"

      open_group(conn)
      assert single_result(conn, [cancel_group_op()])["status"] == "applied"

      result = single_result(conn, [cancel_rooms_op(%{"operation_id" => "op-late"})])
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"
    end

    test "follows the revision contract", %{conn: conn} do
      open_group(conn)
      pay(conn)

      result = cancel_rooms(conn, %{"expected_revision" => 2})
      assert result["revision"] == 3

      result =
        single_result(conn, [
          cancel_rooms_op(%{"operation_id" => "op-stale", "expected_revision" => 2})
        ])

      assert result == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 3
             }

      # A stale revision is rejected before the room domain rules.
      result =
        single_result(conn, [
          cancel_rooms_op(%{
            "operation_id" => "op-stale-2",
            "room_ids" => ["room-z"],
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

      first = cancel_rooms(conn)
      retry = single_result(conn, [cancel_rooms_op()])
      assert retry == first

      group = get_group(conn, "group-81")
      assert group["revision"] == 3
      assert get_ledger(conn)["cash_refunded_cents"] == 5000

      # A remembered rejection replays too.
      rejected =
        single_result(conn, [cancel_rooms_op(%{"operation_id" => "op-bad", "room_ids" => []})])

      assert rejected["code"] == "invalid_rooms"

      assert single_result(conn, [
               cancel_rooms_op(%{"operation_id" => "op-bad", "room_ids" => []})
             ]) ==
               rejected

      # A reused identifier with a different payload conflicts.
      conflict = single_result(conn, [cancel_rooms_op(%{"room_ids" => ["room-b"]})])
      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"
    end
  end

  describe "legacy funding brought forward" do
    # Simulates a group whose funding predates durable operation records:
    # the funding is one unattributed senior block (aggregate cash first,
    # then credit lots in original consumption order) ahead of recorded
    # funding.
    test "allocates the senior block first and keeps entitlements in order", %{conn: conn} do
      # One room for one night at 12000: deposit 2400.
      open_group(conn, %{
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 12000}]
      })

      group_row = Repo.get_by!(Group, group_id: "group-81")
      [room] = Repo.all(from r in Room, where: r.group_id == ^group_row.id)

      legacy_payment =
        Repo.insert!(%CashPayment{
          group_id: group_row.id,
          amount_cents: 1005,
          occurred_on: ~D[2026-10-04],
          operation_id: "op-legacy-pay"
        })

      Repo.insert!(%RoomAllocation{
        room_id: room.id,
        cash_payment_id: legacy_payment.id,
        amount_cents: 1005
      })

      Repo.update_all(
        from(r in Room, where: r.id == ^room.id),
        inc: [cash_paid_cents: 1005]
      )

      Repo.update_all(
        from(g in Group, where: g.id == ^group_row.id),
        inc: [deposit_paid_cents: 1005]
      )

      # Recorded funding follows the senior block.
      pay(conn, %{"operation_id" => "op-pay-recorded", "amount_cents" => 1004})

      group = get_group(conn, "group-81")
      assert room_by_id(group, "room-a")["cash_paid_cents"] == 2009

      # Settling as hotel credit retains the senior block first in the lot's
      # contributions.
      result =
        cancel_rooms(conn, %{"room_ids" => ["room-a"], "refund_method" => "hotel_credit"})

      assert result["credit_issued_cents"] == 2210

      # Charging back the recorded payment revokes only its entitlement:
      # V(2009) - V(1005) = 2210 - 1106 = 1104.
      result =
        single_result(conn, [
          %{
            "operation_id" => "op-chargeback",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay-recorded"
          }
        ])

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 1004

      [lot] = get_credit(conn, "guest-22")["lots"]
      assert lot["remaining_cents"] == 1106
    end
  end
end
