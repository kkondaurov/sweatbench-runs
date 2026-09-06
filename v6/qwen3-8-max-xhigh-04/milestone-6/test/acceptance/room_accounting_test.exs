defmodule GroupStayWeb.Acceptance.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  @guest "guest-22"

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  # Three rooms over two nights (flexible, 20% deposit):
  #   room-a lodging 20000 deposit 4000
  #   room-b lodging 30000 deposit 6000
  #   room-c lodging 40000 deposit 8000
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
          %{"room_id" => "room-b", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-c", "nightly_rate_cents" => 20000}
        ]
      },
      overrides
    )
  end

  defp pay_op(group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay-#{group_id}-#{amount_cents}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp cancel_rooms_op(group_id, room_ids, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-rooms-#{group_id}",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id,
        "room_ids" => room_ids
      },
      overrides
    )
  end

  defp cancel_group_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id
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

  defp rooms(conn, group_id), do: group(conn, group_id)["rooms"]

  defp room(conn, group_id, room_id) do
    Enum.find(rooms(conn, group_id), &(&1["room_id"] == room_id))
  end

  describe "room-level accounting reads" do
    test "every room exposes status, deposit_due_cents, and paid totals" do
      submit(build_conn(), [open_op("group-a")])

      assert rooms(build_conn(), "group-a") == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 10000,
                 "status" => "active",
                 "deposit_due_cents" => 4000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 15000,
                 "status" => "active",
                 "deposit_due_cents" => 6000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-c",
                 "nightly_rate_cents" => 20000,
                 "status" => "active",
                 "deposit_due_cents" => 8000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]
    end

    test "cash funds rooms in their original order, filling one before the next" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 7000)])

      assert room(build_conn(), "group-a", "room-a")["cash_paid_cents"] == 4000
      assert room(build_conn(), "group-a", "room-b")["cash_paid_cents"] == 3000
      assert room(build_conn(), "group-a", "room-c")["cash_paid_cents"] == 0
    end

    test "later payments continue from the fill frontier" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 7000)])
      submit(build_conn(), [pay_op("group-a", 5000)])

      assert room(build_conn(), "group-a", "room-a")["cash_paid_cents"] == 4000
      assert room(build_conn(), "group-a", "room-b")["cash_paid_cents"] == 6000
      assert room(build_conn(), "group-a", "room-c")["cash_paid_cents"] == 2000
    end

    test "group totals describe active rooms only" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 7000)])

      group = group(build_conn(), "group-a")
      assert group["lodging_total_cents"] == 90000
      assert group["deposit_due_cents"] == 18000
      assert group["deposit_paid_cents"] == 7000
      assert group["outstanding_deposit_cents"] == 11000
    end
  end

  describe "cancel_rooms" do
    test "settles only the selected rooms and keeps the group active" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 7000)])

      assert [
               %{
                 "operation_id" => "cancel-rooms-group-a",
                 "status" => "applied",
                 "group_id" => "group-a",
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 3000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = submit(build_conn(), [cancel_rooms_op("group-a", ["room-b"])])

      group = group(build_conn(), "group-a")
      assert group["status"] == "active"
      assert room(build_conn(), "group-a", "room-b")["status"] == "cancelled"
      assert room(build_conn(), "group-a", "room-a")["status"] == "active"
      assert room(build_conn(), "group-a", "room-c")["status"] == "active"
    end

    test "other rooms and their allocations are unchanged" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 7000)])
      submit(build_conn(), [cancel_rooms_op("group-a", ["room-b"])])

      assert room(build_conn(), "group-a", "room-a")["cash_paid_cents"] == 4000
      assert room(build_conn(), "group-a", "room-c")["cash_paid_cents"] == 0
    end

    test "unpaid deposit for the selected rooms ceases to be due" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 7000)])
      submit(build_conn(), [cancel_rooms_op("group-a", ["room-b"])])

      group = group(build_conn(), "group-a")
      # room-a 4000 + room-c 8000 remain due; room-a's 4000 is paid.
      assert group["deposit_due_cents"] == 12000
      assert group["deposit_paid_cents"] == 4000
      assert group["outstanding_deposit_cents"] == 8000
      assert group["lodging_total_cents"] == 60000
    end

    test "returns cancelled_room_ids in the group's original room order" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 18000)])

      assert [%{"cancelled_room_ids" => ["room-a", "room-c"]}] =
               submit(build_conn(), [cancel_rooms_op("group-a", ["room-c", "room-a"])])
    end

    test "computes the hotel-credit bonus once on the combined cash amount" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 18000)])

      # room-a 4000 + room-b 6000 = 10000 combined cash, 10% bonus = 1000.
      assert [%{"status" => "applied", "credit_issued_cents" => 11000}] =
               submit(build_conn(), [
                 cancel_rooms_op("group-a", ["room-a", "room-b"], %{
                   "refund_method" => "hotel_credit"
                 })
               ])
    end

    test "a non-refundable selected settlement retains cash" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 7000)])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 3000}] =
               submit(build_conn(), [
                 cancel_rooms_op("group-a", ["room-b"], %{"occurred_on" => "2026-12-05"})
               ])
    end

    test "hotel credit is not available for a non-refundable settlement" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 7000)])

      assert [%{"status" => "rejected", "code" => "refund_method_not_available"}] =
               submit(build_conn(), [
                 cancel_rooms_op("group-a", ["room-b"], %{
                   "occurred_on" => "2026-12-05",
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert group(build_conn(), "group-a")["status"] == "active"
    end

    test "cancelling every remaining room makes the group cancelled" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 18000)])

      assert [%{"status" => "applied", "cancelled_room_ids" => ["room-a", "room-b", "room-c"]}] =
               submit(build_conn(), [cancel_rooms_op("group-a", ["room-a", "room-b", "room-c"])])

      group = group(build_conn(), "group-a")
      assert group["status"] == "cancelled"
      assert group["deposit_due_cents"] == 0
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0
    end

    test "cancel_group settles only the remaining active rooms" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 18000)])
      submit(build_conn(), [cancel_rooms_op("group-a", ["room-a"])])

      # room-a already refunded 4000; cancelling the group settles room-b and
      # room-c (14000 remaining cash).
      assert [%{"status" => "applied", "refunded_cents" => 14000, "retained_cents" => 0}] =
               submit(build_conn(), [cancel_group_op("group-a")])

      assert group(build_conn(), "group-a")["status"] == "cancelled"
    end

    test "rejects room identifiers that are not distinct active rooms" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 7000)])
      submit(build_conn(), [cancel_rooms_op("group-a", ["room-b"])])

      cases = [
        ["nope"],
        ["room-a", "room-a"],
        ["room-b"],
        ["room-a", "nope"],
        []
      ]

      cases
      |> Enum.with_index()
      |> Enum.each(fn {room_ids, index} ->
        assert [%{"status" => "rejected", "code" => "invalid_rooms"}] =
                 submit(build_conn(), [
                   cancel_rooms_op("group-a", room_ids, %{
                     "operation_id" => "cancel-rooms-invalid-#{index}"
                   })
                 ])
      end)
    end

    test "a missing or non-list room_ids is an invalid operation" do
      submit(build_conn(), [open_op("group-a")])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), [
                 cancel_rooms_op("group-a", []) |> Map.delete("room_ids")
               ])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), [
                 cancel_rooms_op("group-a", [], %{
                   "operation_id" => "cancel-rooms-not-a-list",
                   "room_ids" => "room-a"
                 })
               ])
    end

    test "rejects a missing group and a cancelled group" do
      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               submit(build_conn(), [cancel_rooms_op("nope", ["room-a"])])

      submit(build_conn(), [open_op("group-a"), cancel_group_op("group-a")])

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               submit(build_conn(), [
                 cancel_rooms_op("group-a", ["room-a"], %{
                   "operation_id" => "cancel-rooms-inactive"
                 })
               ])
    end

    test "follows the revision contract" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 7000)])

      assert [%{"status" => "applied", "revision" => 3}] =
               submit(build_conn(), [
                 cancel_rooms_op("group-a", ["room-b"], %{
                   "expected_revision" => 2
                 })
               ])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-a",
                 "expected_revision" => 1,
                 "actual_revision" => 3
               }
             ] =
               submit(build_conn(), [
                 cancel_rooms_op("group-a", ["room-c"], %{
                   "operation_id" => "cancel-rooms-stale",
                   "expected_revision" => 1
                 })
               ])
    end

    test "is durably idempotent" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 7000)])

      [first] = submit(build_conn(), [cancel_rooms_op("group-a", ["room-b"])])
      assert first["status"] == "applied"

      # An exact retry returns the stored result without settling again.
      assert submit(build_conn(), [cancel_rooms_op("group-a", ["room-b"])]) == [first]

      group = group(build_conn(), "group-a")
      assert group["revision"] == 3
      assert group["deposit_paid_cents"] == 4000

      # A different payload under the same identifier conflicts.
      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               submit(build_conn(), [cancel_rooms_op("group-a", ["room-c"])])
    end
  end

  describe "cancel_rooms with applied credit" do
    defp issue_lot(conn, group_id, cash) do
      submit(conn, [open_op(group_id), pay_op(group_id, cash)])

      submit(conn, [
        %{
          "operation_id" => "cancel-#{group_id}",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-01",
          "group_id" => group_id,
          "refund_method" => "hotel_credit"
        }
      ])
    end

    test "restores credit funding a cancelled room to its lot" do
      # group-src: cancel refundably to a credit lot (5000 cash -> 5500 lot).
      issue_lot(build_conn(), "group-src", 5000)

      submit(build_conn(), [open_op("group-dst")])

      submit(build_conn(), [
        %{
          "operation_id" => "credit-group-dst",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-02",
          "group_id" => "group-dst",
          "amount_cents" => 4000
        }
      ])

      # Credit fills room-a (4000 of its 4000 deposit).
      assert room(build_conn(), "group-dst", "room-a")["credit_paid_cents"] == 4000

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0}] =
               submit(build_conn(), [cancel_rooms_op("group-dst", ["room-a"])])

      # The 4000 credit returns to its lot (5500 - 4000 + 4000 = 5500).
      %{"data" => credit} =
        json_response(
          get(build_conn(), "/api/v1/guests/#{@guest}/credit", %{"on" => "2026-11-02"}),
          200
        )

      assert credit["available_cents"] == 5500
    end

    test "non-refundable settlement consumes credit funding the cancelled room" do
      issue_lot(build_conn(), "group-src", 5000)
      submit(build_conn(), [open_op("group-dst")])

      submit(build_conn(), [
        %{
          "operation_id" => "credit-group-dst",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-02",
          "group_id" => "group-dst",
          "amount_cents" => 4000
        }
      ])

      assert [%{"status" => "applied"}] =
               submit(build_conn(), [
                 cancel_rooms_op("group-dst", ["room-a"], %{"occurred_on" => "2026-12-05"})
               ])

      # Consumed credit is not restored.
      %{"data" => credit} =
        json_response(
          get(build_conn(), "/api/v1/guests/#{@guest}/credit", %{"on" => "2026-12-05"}),
          200
        )

      assert credit["available_cents"] == 1500
    end
  end
end
