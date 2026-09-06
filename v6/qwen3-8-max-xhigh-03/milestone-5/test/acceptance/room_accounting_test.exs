defmodule GroupStayWeb.RoomAccountingAcceptanceTest do
  @moduledoc """
  End-to-end walkthrough of room accounting and payment reductions: funding
  fills rooms in order, selected rooms settle independently, recorded cash
  can be reduced or charged back, and funding from before durable operation
  records is carried forward as one unattributed senior block.
  """

  use GroupStayWeb.ConnCase

  alias GroupStay.Credit.Lot
  alias GroupStay.Credit.Application
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @batch_path "/api/v1/partner-batches"

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@batch_path, Jason.encode!(%{operations: operations}))
  end

  defp run(conn, operations) do
    submit(conn, operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp open_op(overrides \\ %{}) do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp cancel_rooms_op(overrides) do
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

  defp reduce_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp chargeback_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp credit_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp fetched_group(conn, group_id \\ "group-81") do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp room(fetched, room_id) do
    Enum.find(fetched["rooms"], &(&1["room_id"] == room_id))
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id \\ "guest-22") do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp statement(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # Opens a funder group, pays it, and cancels it into hotel credit so the
  # guest holds one credit lot.
  defp issue_credit(conn, cancel_op_id, group_id, cash_cents, occurred_on \\ "2026-10-04") do
    run(conn, [
      open_op(%{"operation_id" => cancel_op_id <> "-open", "group_id" => group_id}),
      payment_op(%{
        "operation_id" => cancel_op_id <> "-pay",
        "group_id" => group_id,
        "amount_cents" => cash_cents
      }),
      cancel_op(%{
        "operation_id" => cancel_op_id,
        "group_id" => group_id,
        "occurred_on" => occurred_on,
        "refund_method" => "hotel_credit"
      })
    ])
  end

  describe "room-level accounting" do
    test "cash and credit fund active room deposits in the rooms' original order", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000)
      assert [_] = run(conn, [open_op()])
      assert [paid] = run(conn, [payment_op(%{"amount_cents" => 10_000})])
      assert paid["status"] == "applied"
      assert [credited] = run(conn, [credit_op(%{"amount_cents" => 1_500})])
      assert credited["status"] == "applied"

      group = fetched_group(conn)

      assert room(group, "room-a") == %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 15_000,
               "status" => "active",
               "deposit_due_cents" => 9_000,
               "cash_paid_cents" => 9_000,
               "credit_paid_cents" => 0
             }

      assert room(group, "room-b") == %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 17_500,
               "status" => "active",
               "deposit_due_cents" => 10_500,
               "cash_paid_cents" => 1_000,
               "credit_paid_cents" => 1_500
             }

      assert group["deposit_paid_cents"] == 11_500
      assert group["cash_paid_cents"] == 10_000
      assert group["credit_paid_cents"] == 1_500
      assert group["outstanding_deposit_cents"] == 8_000
    end

    test "new funding operations allocate in operation-processing order, not occurred_on order",
         %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      # Submitted first with a later date, so it must fill rooms first.
      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-x",
                   "occurred_on" => "2026-10-06",
                   "amount_cents" => 9_500
                 })
               ])

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-y",
                   "occurred_on" => "2026-10-04",
                   "amount_cents" => 9_000
                 })
               ])

      # op-pay-y fills room-b, where 9_000 remained after op-pay-x.
      assert [reduced] =
               run(conn, [
                 reduce_op(%{
                   "operation_id" => "op-reduce-y",
                   "payment_operation_id" => "op-pay-y",
                   "amount_cents" => 9_000
                 })
               ])

      assert reduced["status"] == "applied"

      group = fetched_group(conn)
      assert room(group, "room-a")["cash_paid_cents"] == 9_000
      assert room(group, "room-b")["cash_paid_cents"] == 500
    end

    test "group totals describe active rooms only", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 19_500})])

      assert [cancelled] =
               run(conn, [cancel_rooms_op(%{"occurred_on" => "2026-11-26"})])

      assert cancelled["status"] == "applied"

      group = fetched_group(conn)
      assert group["lodging_total_cents"] == 52_500
      assert group["deposit_due_cents"] == 10_500
      assert group["deposit_paid_cents"] == 10_500
      assert group["cash_paid_cents"] == 10_500
      assert group["outstanding_deposit_cents"] == 0

      assert room(group, "room-a")["status"] == "cancelled"
      assert room(group, "room-a")["cash_paid_cents"] == 9_000
      assert room(group, "room-b")["status"] == "active"
    end
  end

  describe "carrying forward legacy funding" do
    defp insert_legacy_state(now) do
      group_id = "group-legacy"

      Repo.insert!(%GroupStay.Groups.Group{
        group_id: group_id,
        guest_id: "guest-legacy",
        property_id: "ams-canal",
        booked_on: ~D[2026-06-01],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-11],
        rate_plan: "flexible",
        lodging_total_cents: 20_000,
        deposit_due_cents: 4_000,
        deposit_paid_cents: 2_800,
        credit_paid_cents: 600,
        inserted_at: now,
        updated_at: now
      })

      for {room_id, position} <- Enum.with_index(~w(room-1 room-2 room-3 room-4)) do
        Repo.insert!(%GroupStay.Groups.Room{
          group_id: group_id,
          room_id: room_id,
          nightly_rate_cents: 5_000,
          position: position,
          inserted_at: now,
          updated_at: now
        })
      end

      lot_1 =
        Repo.insert!(%Lot{
          guest_id: "guest-legacy",
          source_operation_id: "cancel-legacy-1",
          issued_cents: 1_100,
          remaining_cents: 800,
          expires_on: ~D[2027-10-21],
          inserted_at: now,
          updated_at: now
        })

      lot_2 =
        Repo.insert!(%Lot{
          guest_id: "guest-legacy",
          source_operation_id: "cancel-legacy-2",
          issued_cents: 550,
          remaining_cents: 250,
          expires_on: ~D[2027-11-01],
          inserted_at: now,
          updated_at: now
        })

      # Unattributed credit application, consumed before durable records
      # existed.
      Repo.insert!(%Application{
        group_id: group_id,
        lot_id: lot_1.id,
        amount_cents: 300,
        inserted_at: now,
        updated_at: now
      })

      # Credit applied by the recorded operation below; committed after the
      # unattributed application.
      Repo.insert!(%Application{
        group_id: group_id,
        lot_id: lot_2.id,
        amount_cents: 300,
        inserted_at: now,
        updated_at: now
      })

      record = fn operation_id, type, occurred_on, result ->
        payload =
          Jason.encode!(%{
            "operation_id" => operation_id,
            "type" => type,
            "occurred_on" => occurred_on,
            "group_id" => group_id
          })

        Repo.insert!(%Record{
          operation_id: operation_id,
          type: type,
          payload: payload,
          result: Jason.encode!(result),
          inserted_at: now,
          updated_at: now
        })
      end

      # Committed first, with a later occurred_on than the next record.
      record.("op-rec-x", "record_cash_payment", "2026-10-06", %{
        "operation_id" => "op-rec-x",
        "status" => "applied",
        "group_id" => group_id,
        "amount_cents" => 1_000,
        "outstanding_deposit_cents" => 3_000,
        "revision" => 2
      })

      record.("op-rec-y", "record_cash_payment", "2026-10-04", %{
        "operation_id" => "op-rec-y",
        "status" => "applied",
        "group_id" => group_id,
        "amount_cents" => 500,
        "outstanding_deposit_cents" => 2_500,
        "revision" => 3
      })

      record.("op-rec-z", "apply_hotel_credit", "2026-10-05", %{
        "operation_id" => "op-rec-z",
        "status" => "applied",
        "group_id" => group_id,
        "amount_cents" => 300,
        "outstanding_deposit_cents" => 2_200,
        "revision" => 4
      })

      group_id
    end

    test "allocates the senior block first and recorded funding in commit order", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      group_id = insert_legacy_state(now)

      # Carrying funding forward changes no aggregate balance.
      assert ledger(conn) == %{
               "cash_held_cents" => 2_200,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 1_650,
               "credit_shortfall_cents" => 0
             }

      group = fetched_group(conn, group_id)
      assert group["deposit_paid_cents"] == 2_800
      assert group["cash_paid_cents"] == 2_200
      assert group["credit_paid_cents"] == 600
      assert group["outstanding_deposit_cents"] == 1_200

      # The unattributed senior block fills room-1 (cash first, then the
      # legacy credit lot); recorded funding follows in commit order
      # regardless of occurred_on.
      assert room(group, "room-1")["cash_paid_cents"] == 700
      assert room(group, "room-1")["credit_paid_cents"] == 300
      assert room(group, "room-1")["deposit_due_cents"] == 1_000
      assert room(group, "room-2")["cash_paid_cents"] == 1_000
      assert room(group, "room-3")["cash_paid_cents"] == 500
      assert room(group, "room-3")["credit_paid_cents"] == 300
      assert room(group, "room-4")["cash_paid_cents"] == 0

      assert guest_credit(conn, "guest-legacy")["available_cents"] == 1_050

      # Settling a room funded by the senior block refunds its cash and
      # restores its legacy credit.
      assert [settled] =
               run(conn, [
                 cancel_rooms_op(%{
                   "operation_id" => "op-cancel-legacy",
                   "group_id" => group_id,
                   "room_ids" => ["room-1"],
                   "occurred_on" => "2026-11-26"
                 })
               ])

      assert settled["status"] == "applied"
      assert settled["refunded_cents"] == 700
      assert settled["retained_cents"] == 0

      assert guest_credit(conn, "guest-legacy")["available_cents"] == 1_350
      assert ledger(conn)["cash_refunded_cents"] == 700
      assert ledger(conn)["cash_held_cents"] == 1_500
      assert ledger(conn)["credit_liability_cents"] == 1_650

      # Recorded funding keeps its operation identity and can be reduced.
      assert [reduced] =
               run(conn, [
                 reduce_op(%{
                   "operation_id" => "op-reduce-y",
                   "payment_operation_id" => "op-rec-y",
                   "amount_cents" => 500
                 })
               ])

      assert reduced["status"] == "applied"
      assert reduced["group_id"] == group_id
      assert fetched_group(conn, group_id)["outstanding_deposit_cents"] == 1_700

      # Legacy funding has no durable identity and cannot be targeted.
      assert [rejected] =
               run(conn, [
                 reduce_op(%{
                   "operation_id" => "op-reduce-legacy",
                   "payment_operation_id" => "cancel-legacy-1",
                   "amount_cents" => 100
                 })
               ])

      assert rejected["status"] == "rejected"
      assert rejected["code"] == "operation_not_found"
    end
  end

  describe "cancel_rooms" do
    test "settles selected rooms and leaves other rooms unchanged", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 10_000})])

      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{"occurred_on" => "2026-11-26", "room_ids" => ["room-b"]})
               ])

      assert result == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 1_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      group = fetched_group(conn)
      assert group["status"] == "active"
      assert group["deposit_due_cents"] == 9_000
      assert group["deposit_paid_cents"] == 9_000
      assert group["outstanding_deposit_cents"] == 0
      assert room(group, "room-a")["cash_paid_cents"] == 9_000
      assert room(group, "room-b")["status"] == "cancelled"
      assert room(group, "room-b")["cash_paid_cents"] == 1_000

      assert ledger(conn)["cash_held_cents"] == 9_000
      assert ledger(conn)["cash_refunded_cents"] == 1_000
    end

    test "returns cancelled_room_ids in the group's original room order", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 19_500})])

      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{
                   "occurred_on" => "2026-11-26",
                   "room_ids" => ["room-b", "room-a"]
                 })
               ])

      assert result["cancelled_room_ids"] == ["room-a", "room-b"]
      assert result["refunded_cents"] == 19_500
      assert fetched_group(conn)["status"] == "cancelled"
    end

    test "retains cash for a non-refundable settlement", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 19_500})])

      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{"occurred_on" => "2026-12-01", "room_ids" => ["room-a"]})
               ])

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 9_000
      assert result["credit_issued_cents"] == 0

      group = fetched_group(conn)
      assert group["status"] == "active"
      assert group["deposit_paid_cents"] == 10_500
      assert ledger(conn)["cash_retained_cents"] == 9_000
    end

    test "computes the hotel-credit bonus once on the combined cash amount", %{conn: conn} do
      assert [_] =
               run(conn, [
                 open_op(%{
                   "arrival_on" => "2026-12-10",
                   "departure_on" => "2026-12-11",
                   "rooms" => [
                     %{"room_id" => "room-a", "nightly_rate_cents" => 5_025},
                     %{"room_id" => "room-b", "nightly_rate_cents" => 5_025}
                   ]
                 })
               ])

      assert [_] =
               run(conn, [payment_op(%{"operation_id" => "op-pay-1", "amount_cents" => 1_005})])

      assert [_] =
               run(conn, [payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1_005})])

      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{
                   "occurred_on" => "2026-11-26",
                   "room_ids" => ["room-b", "room-a"],
                   "refund_method" => "hotel_credit"
                 })
               ])

      # 10% of the combined 2010 rounds to 201; per-room bonuses would have
      # issued 1106 + 1106 = 2212.
      assert result["credit_issued_cents"] == 2_211
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      assert guest_credit(conn)["available_cents"] == 2_211
      assert ledger(conn)["cash_converted_to_credit_cents"] == 2_010
      assert ledger(conn)["credit_liability_cents"] == 2_211
    end

    test "restores applied credit to its original lot on a refundable settlement", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000)
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [credit_op(%{"amount_cents" => 1_500})])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 500})])

      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{"occurred_on" => "2026-11-26", "room_ids" => ["room-a"]})
               ])

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 500
      assert result["credit_issued_cents"] == 0

      assert guest_credit(conn)["available_cents"] == 2_200
      assert ledger(conn)["credit_liability_cents"] == 2_200

      group = fetched_group(conn)
      assert room(group, "room-a")["credit_paid_cents"] == 1_500
      assert group["credit_paid_cents"] == 0
    end

    test "unpaid deposit for settled rooms ceases to be due", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 5_000})])

      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{"occurred_on" => "2026-11-26", "room_ids" => ["room-a"]})
               ])

      assert result["refunded_cents"] == 5_000

      group = fetched_group(conn)
      assert group["deposit_due_cents"] == 10_500
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 10_500
    end

    test "the group becomes cancelled when no active rooms remain", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 19_500})])

      assert [first] =
               run(conn, [
                 cancel_rooms_op(%{
                   "operation_id" => "op-cancel-1",
                   "occurred_on" => "2026-11-26",
                   "room_ids" => ["room-a"]
                 })
               ])

      assert first["status"] == "applied"
      assert fetched_group(conn)["status"] == "active"

      assert [second] =
               run(conn, [
                 cancel_rooms_op(%{
                   "operation_id" => "op-cancel-2",
                   "occurred_on" => "2026-11-26",
                   "room_ids" => ["room-b"]
                 })
               ])

      assert second["status"] == "applied"

      group = fetched_group(conn)
      assert group["status"] == "cancelled"
      assert group["deposit_due_cents"] == 0
      assert group["deposit_paid_cents"] == 0

      assert [result] = run(conn, [payment_op(%{"operation_id" => "op-late"})])
      assert result["code"] == "group_not_active"

      assert [result] = run(conn, [cancel_op(%{"operation_id" => "op-cancel-again"})])
      assert result["code"] == "group_not_active"
    end

    test "cancel_group settles only the remaining active rooms", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 19_500})])

      assert [_] =
               run(conn, [
                 cancel_rooms_op(%{
                   "occurred_on" => "2026-12-01",
                   "room_ids" => ["room-a"]
                 })
               ])

      assert [result] = run(conn, [cancel_op(%{"occurred_on" => "2026-12-01"})])

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 10_500,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      group = fetched_group(conn)
      assert group["status"] == "cancelled"
      assert ledger(conn)["cash_retained_cents"] == 19_500
    end

    test "rejects room identifiers that are not distinct active rooms of the group", %{conn: conn} do
      assert [_] =
               run(conn, [
                 open_op(%{"group_id" => "group-other", "operation_id" => "op-open-other"})
               ])

      assert [_] = run(conn, [open_op()])

      assert [_] =
               run(conn, [
                 cancel_rooms_op(%{
                   "operation_id" => "op-cancel-one",
                   "occurred_on" => "2026-11-26",
                   "room_ids" => ["room-a"]
                 })
               ])

      for {room_ids, i} <-
            Enum.with_index([
              ["room-z"],
              ["room-a", "room-a"],
              ["room-a"],
              ["room-a", "room-b"],
              ["room-a", "room-c"],
              []
            ]) do
        assert [result] =
                 run(conn, [
                   cancel_rooms_op(%{
                     "operation_id" => "op-cancel-bad-#{i}",
                     "room_ids" => room_ids
                   })
                 ])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_rooms"
      end

      for {room_ids, i} <- Enum.with_index([["room-a", 5], ["room-a", nil], "room-a"]) do
        assert [result] =
                 run(conn, [
                   cancel_rooms_op(%{
                     "operation_id" => "op-cancel-unusable-#{i}",
                     "room_ids" => room_ids
                   })
                 ])

        assert result["status"] == "rejected"
      end

      group = fetched_group(conn)
      assert group["revision"] == 2
      assert room(group, "room-b")["status"] == "active"
    end

    test "rejects hotel credit for a non-refundable settlement without changing the group", %{
      conn: conn
    } do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op()])

      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{
                   "occurred_on" => "2026-12-01",
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert result == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      group = fetched_group(conn)
      assert group["status"] == "active"
      assert group["revision"] == 2
    end

    test "rejects missing or unusable room_ids as an invalid operation", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{"operation_id" => "op-cancel-nil", "room_ids" => nil})
               ])

      assert result["code"] == "invalid_operation"

      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{"operation_id" => "op-cancel-string", "room_ids" => "room-a"})
               ])

      assert result["code"] == "invalid_operation"

      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{"operation_id" => "op-cancel-nogroup", "group_id" => nil})
               ])

      assert result["code"] == "invalid_operation"
    end

    test "rejects a missing or inactive group", %{conn: conn} do
      assert [result] = run(conn, [cancel_rooms_op(%{"group_id" => "group-missing"})])
      assert result["code"] == "group_not_found"

      assert [_, _] = run(conn, [open_op(), cancel_op()])
      assert [result] = run(conn, [cancel_rooms_op(%{"operation_id" => "op-cancel-late"})])
      assert result["code"] == "group_not_active"
    end

    test "follows the revision contract", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      # A stale revision is rejected before room validation.
      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{
                   "expected_revision" => 5,
                   "room_ids" => ["room-z"]
                 })
               ])

      assert result == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 5,
               "actual_revision" => 1
             }

      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{
                   "operation_id" => "op-cancel-match",
                   "expected_revision" => 1,
                   "room_ids" => ["room-a"]
                 })
               ])

      assert result["status"] == "applied"
      assert result["revision"] == 2

      # Rejections never increment the revision.
      assert [result] =
               run(conn, [
                 cancel_rooms_op(%{
                   "operation_id" => "op-cancel-stale",
                   "expected_revision" => 1
                 })
               ])

      assert result["code"] == "stale_revision"
      assert fetched_group(conn)["revision"] == 2
    end

    test "is durably idempotent", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 19_500})])

      operation = cancel_rooms_op(%{"occurred_on" => "2026-11-26", "room_ids" => ["room-a"]})
      assert [first] = run(conn, [operation])
      assert first["status"] == "applied"

      assert [retry] = run(conn, [operation])
      assert retry == first

      group = fetched_group(conn)
      assert group["revision"] == 3
      assert group["deposit_paid_cents"] == 10_500
      assert ledger(conn)["cash_refunded_cents"] == 9_000
    end
  end

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the deposit", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 12_000})])

      assert [result] = run(conn, [reduce_op(%{"amount_cents" => 1_000})])

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 8_500,
               "revision" => 3
             }

      group = fetched_group(conn)
      # The reduction comes out of room-b first, the last room the payment
      # filled.
      assert room(group, "room-a")["cash_paid_cents"] == 9_000
      assert room(group, "room-b")["cash_paid_cents"] == 2_000
      assert group["deposit_paid_cents"] == 11_000

      assert ledger(conn)["cash_held_cents"] == 11_000
      assert ledger(conn)["cash_reduced_cents"] == 1_000
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 12_000})])

      assert [first] =
               run(conn, [reduce_op(%{"operation_id" => "op-reduce-1", "amount_cents" => 1_000})])

      assert first["status"] == "applied"

      assert [second] =
               run(conn, [reduce_op(%{"operation_id" => "op-reduce-2", "amount_cents" => 2_000})])

      assert second["status"] == "applied"
      assert second["outstanding_deposit_cents"] == 10_500

      # The complete remaining held portion is valid.
      assert [third] =
               run(conn, [reduce_op(%{"operation_id" => "op-reduce-3", "amount_cents" => 9_000})])

      assert third["status"] == "applied"
      assert third["outstanding_deposit_cents"] == 19_500

      group = fetched_group(conn)
      assert room(group, "room-a")["cash_paid_cents"] == 0
      assert room(group, "room-b")["cash_paid_cents"] == 0
      assert group["deposit_paid_cents"] == 0

      assert ledger(conn)["cash_reduced_cents"] == 12_000
      assert ledger(conn)["cash_held_cents"] == 0

      assert statement(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 12_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 12_000,
               "charged_back_cents" => 0
             }

      # Nothing held remains, so the payment can never accept a reduction.
      assert [rejected] =
               run(conn, [reduce_op(%{"operation_id" => "op-reduce-4", "amount_cents" => 1})])

      assert rejected["status"] == "rejected"
      assert rejected["code"] == "payment_not_reducible"
    end

    test "rejects an amount exceeding the currently held cash", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 12_000})])

      assert [result] = run(conn, [reduce_op(%{"amount_cents" => 12_001})])
      assert result["status"] == "rejected"
      assert result["code"] == "reduction_exceeds_held_cash"

      group = fetched_group(conn)
      assert group["deposit_paid_cents"] == 12_000
      assert group["revision"] == 2
      assert ledger(conn)["cash_reduced_cents"] == 0
    end

    test "rejects non-positive amounts", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op()])

      for {amount, i} <- Enum.with_index([0, -100]) do
        assert [result] =
                 run(conn, [
                   reduce_op(%{"operation_id" => "op-reduce-bad-#{i}", "amount_cents" => amount})
                 ])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_amount"
      end

      assert fetched_group(conn)["deposit_paid_cents"] == 5_000
      assert fetched_group(conn)["revision"] == 2
    end

    test "rejects targets that can never accept a positive reduction", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])

      assert [rejected] =
               run(conn, [payment_op(%{"operation_id" => "op-pay-bad", "amount_cents" => 99_999})])

      assert rejected["code"] == "payment_exceeds_outstanding"

      for {payment_operation_id, i} <-
            Enum.with_index(["op-never-seen", "op-open", "op-pay-bad"]) do
        assert [result] =
                 run(conn, [
                   reduce_op(%{
                     "operation_id" => "op-reduce-target-#{i}",
                     "payment_operation_id" => payment_operation_id
                   })
                 ])

        assert result["status"] == "rejected"

        assert result["code"] ==
                 if(payment_operation_id == "op-never-seen",
                   do: "operation_not_found",
                   else: "payment_not_reducible"
                 )
      end

      # A payment whose cash is fully settled is no longer reducible.
      assert [_, _] =
               run(conn, [
                 open_op(%{"group_id" => "group-settled", "operation_id" => "op-open-settled"}),
                 payment_op(%{
                   "operation_id" => "op-pay-settled",
                   "group_id" => "group-settled",
                   "amount_cents" => 5_000
                 })
               ])

      assert [_] =
               run(conn, [
                 cancel_op(%{
                   "group_id" => "group-settled",
                   "operation_id" => "op-cancel-settled",
                   "occurred_on" => "2026-11-26"
                 })
               ])

      assert [result] =
               run(conn, [
                 reduce_op(%{
                   "operation_id" => "op-reduce-settled",
                   "payment_operation_id" => "op-pay-settled"
                 })
               ])

      assert result["code"] == "payment_not_reducible"
      assert fetched_group(conn)["revision"] == 2
    end

    test "never rewrites the target payment's stored result", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [paid] = run(conn, [payment_op(%{"amount_cents" => 12_000})])

      assert [_] = run(conn, [reduce_op(%{"amount_cents" => 4_000})])

      # Retrying the original payment returns its exact original result
      # without reapplying cash, even though the group state now differs.
      assert [retry] = run(conn, [payment_op(%{"amount_cents" => 12_000})])
      assert retry == paid

      group = fetched_group(conn)
      assert group["deposit_paid_cents"] == 8_000
      assert group["revision"] == 3
    end

    test "is durably idempotent", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 12_000})])

      operation = reduce_op(%{"amount_cents" => 1_000})
      assert [first] = run(conn, [operation])
      assert first["status"] == "applied"

      assert [retry] = run(conn, [operation])
      assert retry == first

      assert fetched_group(conn)["deposit_paid_cents"] == 11_000
      assert ledger(conn)["cash_reduced_cents"] == 1_000
    end

    test "follows the revision contract of the payment's group", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 12_000})])

      assert [result] =
               run(conn, [
                 reduce_op(%{"operation_id" => "op-reduce-stale", "expected_revision" => 9})
               ])

      assert result == %{
               "operation_id" => "op-reduce-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 2
             }

      assert [result] =
               run(conn, [
                 reduce_op(%{"operation_id" => "op-reduce-match", "expected_revision" => 2})
               ])

      assert result["status"] == "applied"
      assert result["revision"] == 3
      assert fetched_group(conn)["revision"] == 3
    end

    test "only held cash is reducible after a partial settlement", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 12_000})])

      assert [_] =
               run(conn, [
                 cancel_rooms_op(%{
                   "occurred_on" => "2026-11-26",
                   "room_ids" => ["room-b"]
                 })
               ])

      assert [result] = run(conn, [reduce_op(%{"amount_cents" => 9_000})])
      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 9_000

      assert statement(conn, "op-pay")["refunded_cents"] == 3_000
      assert statement(conn, "op-pay")["reduced_cents"] == 9_000
      assert statement(conn, "op-pay")["held_cents"] == 0
    end
  end

  describe "charge_back_payment" do
    test "reverses held cash and reopens the deposit", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 12_000})])

      assert [result] = run(conn, [chargeback_op()])

      assert result == %{
               "operation_id" => "op-chargeback",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 12_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 3
             }

      group = fetched_group(conn)
      assert group["deposit_paid_cents"] == 0
      assert room(group, "room-a")["cash_paid_cents"] == 0
      assert room(group, "room-b")["cash_paid_cents"] == 0

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 12_000
    end

    test "reclassifies refunded and retained settlements of a cancelled group", %{conn: conn} do
      assert [_, _, _] =
               run(conn, [
                 open_op(%{"group_id" => "group-refunded", "operation_id" => "op-open-1"}),
                 payment_op(%{
                   "operation_id" => "op-pay-refunded",
                   "group_id" => "group-refunded",
                   "amount_cents" => 5_000
                 }),
                 cancel_op(%{
                   "operation_id" => "op-cancel-refunded",
                   "group_id" => "group-refunded",
                   "occurred_on" => "2026-11-26"
                 })
               ])

      assert [_, _, _] =
               run(conn, [
                 open_op(%{"group_id" => "group-retained", "operation_id" => "op-open-2"}),
                 payment_op(%{
                   "operation_id" => "op-pay-retained",
                   "group_id" => "group-retained",
                   "amount_cents" => 5_000
                 }),
                 cancel_op(%{
                   "operation_id" => "op-cancel-retained",
                   "group_id" => "group-retained",
                   "occurred_on" => "2026-12-01"
                 })
               ])

      assert [refunded_cb] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-1",
                   "payment_operation_id" => "op-pay-refunded"
                 })
               ])

      assert refunded_cb["status"] == "applied"
      assert refunded_cb["charged_back_cents"] == 5_000
      assert refunded_cb["group_id"] == "group-refunded"
      assert refunded_cb["outstanding_deposit_cents"] == 0

      assert [retained_cb] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-2",
                   "payment_operation_id" => "op-pay-retained"
                 })
               ])

      assert retained_cb["status"] == "applied"
      assert retained_cb["charged_back_cents"] == 5_000

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 10_000,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }

      # The historical settlement is not reversed or reissued: the groups
      # stay cancelled, and the chargeback advanced each payment group's
      # revision exactly once.
      assert fetched_group(conn, "group-refunded")["status"] == "cancelled"
      assert fetched_group(conn, "group-refunded")["revision"] == 4
      assert fetched_group(conn, "group-retained")["revision"] == 4
    end

    test "moves converted principal and revokes the entitlement from the lot", %{conn: conn} do
      assert [_] =
               run(conn, [
                 open_op(%{"group_id" => "group-convert", "operation_id" => "op-open-c"})
               ])

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-convert",
                   "group_id" => "group-convert",
                   "amount_cents" => 5_000
                 })
               ])

      assert [_] =
               run(conn, [
                 cancel_op(%{
                   "operation_id" => "op-cancel-convert",
                   "group_id" => "group-convert",
                   "occurred_on" => "2026-10-20",
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert guest_credit(conn)["available_cents"] == 5_500

      assert [result] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-convert",
                   "payment_operation_id" => "op-pay-convert"
                 })
               ])

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 5_000

      # The complete entitlement (principal plus bonus) is revoked from the
      # lot's remaining balance.
      assert guest_credit(conn)["available_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 5_000
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "unrecovered entitlement becomes a shortfall while credit stays applied", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 5_000)

      assert [_] = run(conn, [open_op()])
      assert [credited] = run(conn, [credit_op(%{"amount_cents" => 5_500})])
      assert credited["status"] == "applied"

      assert [result] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-fund",
                   "payment_operation_id" => "op-cancel-fund-pay"
                 })
               ])

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 5_000
      assert result["group_id"] == "group-fund"

      # The lot had no remaining balance, so the whole entitlement is
      # unrecovered; the credit applied to group-81 covers the shortfall.
      assert guest_credit(conn)["available_cents"] == 0

      ledger = ledger(conn)
      assert ledger["credit_shortfall_cents"] == 5_500
      # Liability still includes the applied credit covered by the shortfall.
      assert ledger["credit_liability_cents"] == 5_500

      # The chargeback increments only the original payment group's revision.
      assert fetched_group(conn, "group-fund")["revision"] == 4
      assert fetched_group(conn)["revision"] == 2

      # A refundable settlement restores the credit, which extinguishes the
      # clawback before becoming available; nothing remains.
      assert [settled] = run(conn, [cancel_op(%{"occurred_on" => "2026-11-26"})])
      assert settled["status"] == "applied"

      assert guest_credit(conn)["available_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "absorption extinguishes clawback before making credit available", %{conn: conn} do
      assert [_] =
               run(conn, [
                 open_op(%{"group_id" => "group-fund", "operation_id" => "op-open-fund"})
               ])

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-small",
                   "group_id" => "group-fund",
                   "amount_cents" => 500
                 })
               ])

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-large",
                   "group_id" => "group-fund",
                   "amount_cents" => 4_500
                 })
               ])

      assert [_] =
               run(conn, [
                 cancel_op(%{
                   "operation_id" => "op-cancel-fund",
                   "group_id" => "group-fund",
                   "occurred_on" => "2026-10-20",
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert guest_credit(conn)["available_cents"] == 5_500

      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [credit_op(%{"amount_cents" => 5_500})])

      # Entitlements telescope over the combined cash: the small payment's
      # share is 500 + 50 = 550, the large payment's is 5500 - 550 = 4950.
      assert [result] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-small",
                   "payment_operation_id" => "op-pay-small"
                 })
               ])

      assert result["charged_back_cents"] == 500
      assert ledger(conn)["credit_shortfall_cents"] == 550

      assert [settled] = run(conn, [cancel_op(%{"occurred_on" => "2026-11-26"})])
      assert settled["status"] == "applied"
      assert settled["refunded_cents"] == 0

      # The restored 5500 extinguishes the 550 clawback first; only the
      # excess becomes available again.
      assert guest_credit(conn)["available_cents"] == 4_950
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 4_950
    end

    test "a non-refundable settlement of applied credit reduces the shortfall", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 5_000)
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [credit_op(%{"amount_cents" => 5_500})])

      assert [_] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-fund",
                   "payment_operation_id" => "op-cancel-fund-pay"
                 })
               ])

      assert ledger(conn)["credit_shortfall_cents"] == 5_500

      # Inside the refund window the applied credit is consumed; it is no
      # longer applied to an active group, so the shortfall disappears.
      assert [settled] = run(conn, [cancel_op(%{"occurred_on" => "2026-12-01"})])
      assert settled["status"] == "applied"
      assert settled["retained_cents"] == 0

      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "assigns entitlement in funding order with the unattributed senior block first", %{
      conn: conn
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%GroupStay.Groups.Group{
        group_id: "group-senior",
        guest_id: "guest-senior",
        property_id: "ams-canal",
        booked_on: ~D[2026-06-01],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-11],
        rate_plan: "flexible",
        lodging_total_cents: 50,
        deposit_due_cents: 10,
        deposit_paid_cents: 5,
        inserted_at: now,
        updated_at: now
      })

      Repo.insert!(%GroupStay.Groups.Room{
        group_id: "group-senior",
        room_id: "room-1",
        nightly_rate_cents: 50,
        position: 0,
        inserted_at: now,
        updated_at: now
      })

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-junior",
                   "group_id" => "group-senior",
                   "amount_cents" => 5
                 })
               ])

      assert [converted] =
               run(conn, [
                 cancel_rooms_op(%{
                   "operation_id" => "op-cancel-senior",
                   "group_id" => "group-senior",
                   "occurred_on" => "2026-11-26",
                   "room_ids" => ["room-1"],
                   "refund_method" => "hotel_credit"
                 })
               ])

      # The lot is worth 10 + 1 = 11.
      assert converted["credit_issued_cents"] == 11
      assert guest_credit(conn, "guest-senior")["available_cents"] == 11

      # The senior block leads the funding order: its 10% bonus value is
      # 5 + 1 = 6, so the payment's entitlement is 11 - 6 = 5, not its own
      # standalone bonus value of 6.
      assert [result] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-junior",
                   "payment_operation_id" => "op-pay-junior"
                 })
               ])

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 5
      assert guest_credit(conn, "guest-senior")["available_cents"] == 6
    end

    test "revokes entitlements independently across the lots a payment contributed to", %{
      conn: conn
    } do
      assert [_] =
               run(conn, [
                 open_op(%{
                   "arrival_on" => "2026-12-10",
                   "departure_on" => "2026-12-11",
                   "rooms" => [
                     %{"room_id" => "room-a", "nightly_rate_cents" => 5_025},
                     %{"room_id" => "room-b", "nightly_rate_cents" => 5_025}
                   ]
                 })
               ])

      assert [_] = run(conn, [payment_op(%{"amount_cents" => 2_010})])

      assert [first] =
               run(conn, [
                 cancel_rooms_op(%{
                   "operation_id" => "op-cancel-first",
                   "occurred_on" => "2026-11-26",
                   "room_ids" => ["room-a"],
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert [second] =
               run(conn, [
                 cancel_rooms_op(%{
                   "operation_id" => "op-cancel-second",
                   "occurred_on" => "2026-11-26",
                   "room_ids" => ["room-b"],
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert first["credit_issued_cents"] == 1_106
      assert second["credit_issued_cents"] == 1_106
      assert guest_credit(conn)["available_cents"] == 2_212

      assert [result] = run(conn, [chargeback_op()])
      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 2_010

      # The payment's entitlement is revoked from each lot it funded.
      assert guest_credit(conn)["available_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 2_010
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "absorption occurs before the expiry check when credit returns late", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 5_000, "2026-10-20")
      assert [_] = run(conn, [open_op()])

      assert [_] =
               run(conn, [credit_op(%{"occurred_on" => "2026-10-22", "amount_cents" => 5_500})])

      assert [_] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-fund",
                   "occurred_on" => "2028-06-01",
                   "payment_operation_id" => "op-cancel-fund-pay"
                 })
               ])

      assert ledger(conn)["credit_shortfall_cents"] == 5_500

      # Move the stay far enough out that the settlement is refundable after
      # the lot's expiry date (2027-10-21) has passed.
      assert [moved] =
               run(conn, [
                 %{
                   "operation_id" => "op-move-late",
                   "type" => "reschedule_group",
                   "occurred_on" => "2028-06-01",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2028-12-10"
                 }
               ])

      assert moved["status"] == "applied"

      assert [settled] = run(conn, [cancel_op(%{"occurred_on" => "2028-06-02"})])
      assert settled["status"] == "applied"
      assert settled["refunded_cents"] == 0

      # The restored credit extinguishes the clawback first; the lot is
      # already expired, so nothing becomes available.
      assert guest_credit(conn)["available_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "rejects targets that cannot be charged back", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])

      assert [rejected] =
               run(conn, [
                 payment_op(%{"operation_id" => "op-pay-rejected", "amount_cents" => 99_999})
               ])

      assert rejected["code"] == "payment_exceeds_outstanding"

      for {payment_operation_id, expected_code} <- [
            {"op-never-seen", "operation_not_found"},
            {"op-open", "payment_not_chargeable"},
            {"op-pay-rejected", "payment_not_chargeable"}
          ] do
        assert [result] =
                 run(conn, [
                   chargeback_op(%{
                     "operation_id" => "op-cb-#{payment_operation_id}",
                     "payment_operation_id" => payment_operation_id
                   })
                 ])

        assert result["status"] == "rejected"
        assert result["code"] == expected_code
      end

      # A fully reduced payment has nothing left to charge back.
      assert [_] =
               run(conn, [
                 reduce_op(%{
                   "operation_id" => "op-reduce-all",
                   "payment_operation_id" => "op-pay-1",
                   "amount_cents" => 5_000
                 })
               ])

      assert [result] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-reduced",
                   "payment_operation_id" => "op-pay-1"
                 })
               ])

      assert result["code"] == "payment_not_chargeable"

      # A charged-back payment cannot be charged back again.
      assert [_] = run(conn, [payment_op(%{"operation_id" => "op-pay-2"})])

      assert [applied] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-once",
                   "payment_operation_id" => "op-pay-2"
                 })
               ])

      assert applied["status"] == "applied"

      assert [again] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-twice",
                   "payment_operation_id" => "op-pay-2"
                 })
               ])

      assert again["code"] == "payment_not_chargeable"
      assert fetched_group(conn)["revision"] == 5
    end

    test "is durably idempotent and follows the revision contract", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op()])

      assert [stale] =
               run(conn, [
                 chargeback_op(%{"operation_id" => "op-cb-stale", "expected_revision" => 9})
               ])

      assert stale == %{
               "operation_id" => "op-cb-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 2
             }

      operation = chargeback_op(%{"operation_id" => "op-cb-match", "expected_revision" => 2})
      assert [first] = run(conn, [operation])
      assert first["status"] == "applied"
      assert first["revision"] == 3

      assert [retry] = run(conn, [operation])
      assert retry == first

      assert fetched_group(conn)["revision"] == 3
      assert ledger(conn)["cash_charged_back_cents"] == 5_000
    end

    test "never rewrites the original payment's stored result", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [paid] = run(conn, [payment_op()])

      assert [_] = run(conn, [chargeback_op()])

      assert [retry] = run(conn, [payment_op()])
      assert retry == paid
    end
  end

  describe "operation validation" do
    test "rejects new operations missing data needed to identify and apply them", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op()])

      for {overrides, i} <-
            Enum.with_index([
              %{"type" => "cancel_rooms", "group_id" => nil, "room_ids" => ["room-a"]},
              %{"type" => "cancel_rooms", "room_ids" => nil},
              %{
                "type" => "reduce_cash_payment",
                "payment_operation_id" => nil,
                "amount_cents" => 1
              },
              %{"type" => "reduce_cash_payment", "payment_operation_id" => "op-pay"},
              %{"type" => "charge_back_payment", "payment_operation_id" => nil},
              %{"type" => "charge_back_payment"}
            ]) do
        operation =
          %{
            "operation_id" => "op-incomplete-#{i}",
            "occurred_on" => "2026-10-05"
          }
          |> Map.merge(overrides)

        assert [result] = run(conn, [operation])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end

      assert [result] =
               run(conn, [
                 %{
                   "operation_id" => "op-no-date",
                   "type" => "reduce_cash_payment",
                   "payment_operation_id" => "op-pay",
                   "amount_cents" => 1
                 }
               ])

      assert result["code"] == "invalid_operation"

      assert fetched_group(conn)["revision"] == 2
      assert ledger(conn)["cash_reduced_cents"] == 0
    end
  end

  describe "reconciling one payment" do
    test "reports the current disposition of a payment's cash", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 12_000})])

      # Settle room-b refundably, then reduce part of the held remainder.
      assert [_] =
               run(conn, [
                 cancel_rooms_op(%{"occurred_on" => "2026-11-26", "room_ids" => ["room-b"]})
               ])

      assert [_] = run(conn, [reduce_op(%{"amount_cents" => 1_000})])

      data = statement(conn, "op-pay")

      assert data == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 12_000,
               "held_cents" => 8_000,
               "refunded_cents" => 3_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 0
             }

      # The dispositions agree with the ledger and the room views.
      ledger = ledger(conn)
      assert ledger["cash_held_cents"] == 8_000
      assert ledger["cash_refunded_cents"] == 3_000
      assert ledger["cash_reduced_cents"] == 1_000

      group = fetched_group(conn)
      assert room(group, "room-a")["cash_paid_cents"] == 8_000
      assert room(group, "room-b")["cash_paid_cents"] == 3_000

      # Reading a statement never changes state.
      assert statement(conn, "op-pay") == data
      assert ledger(conn) == ledger
    end

    test "a chargeback reclassifies every remaining disposition", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 12_000})])

      assert [_] =
               run(conn, [
                 cancel_rooms_op(%{"occurred_on" => "2026-11-26", "room_ids" => ["room-b"]})
               ])

      assert [_] = run(conn, [reduce_op(%{"amount_cents" => 1_000})])
      assert [_] = run(conn, [chargeback_op()])

      assert statement(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 12_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 11_000
             }
    end

    test "all seven monetary fields are present, including when zero", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op()])

      data = statement(conn, "op-pay")

      assert Enum.sort(Map.keys(data)) ==
               Enum.sort(
                 ~w(payment_operation_id original_group_id recorded_cents held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
               )

      assert data["recorded_cents"] == 5_000
      assert data["held_cents"] == 5_000
      assert data["refunded_cents"] == 0
      assert data["retained_cents"] == 0
      assert data["converted_to_credit_cents"] == 0
      assert data["reduced_cents"] == 0
      assert data["charged_back_cents"] == 0
    end

    test "returns 404 when no durable operation record exists", %{conn: conn} do
      response = get(conn, "/api/v1/payments/op-never-seen")

      assert json_response(response, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns 422 when the record is not an applied cash payment", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [rejected] = run(conn, [payment_op(%{"amount_cents" => 99_999})])
      assert rejected["code"] == "payment_exceeds_outstanding"

      for payment_operation_id <- ["op-open", "op-pay"] do
        response = get(conn, "/api/v1/payments/#{payment_operation_id}")

        assert json_response(response, 422) ==
                 %{"error" => %{"code" => "payment_not_reconcilable"}}
      end
    end
  end
end
