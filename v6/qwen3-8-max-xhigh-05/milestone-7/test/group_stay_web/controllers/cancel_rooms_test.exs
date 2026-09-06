defmodule GroupStayWeb.CancelRoomsTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
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
    %{"results" => [result]} = submit_batch(conn, [cancel_rooms_op(overrides)])
    result
  end

  defp room_by_id(data, room_id) do
    Enum.find(data["rooms"], &(&1["room_id"] == room_id))
  end

  describe "settling selected rooms" do
    test "settles the selected rooms and leaves the others unchanged", %{conn: conn} do
      pay_group(conn, "group-81", 19500)

      result = cancel_rooms(conn)

      assert result == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-a"],
               "refunded_cents" => 9000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      data = group_data(conn, "group-81")
      assert data["status"] == "active"
      assert data["lodging_total_cents"] == 52500
      assert data["deposit_due_cents"] == 10500
      assert data["deposit_paid_cents"] == 10500
      assert data["outstanding_deposit_cents"] == 0

      assert room_by_id(data, "room-a")["status"] == "cancelled"
      assert room_by_id(data, "room-b")["status"] == "active"
      assert room_by_id(data, "room-b")["cash_paid_cents"] == 10500

      ledger = ledger_data(conn)
      assert ledger["cash_held_cents"] == 10500
      assert ledger["cash_refunded_cents"] == 9000
    end

    test "returns cancelled_room_ids in the group's original room order", %{conn: conn} do
      pay_group(conn, "group-81", 19500)

      result = cancel_rooms(conn, %{"room_ids" => ["room-b", "room-a"]})

      assert result["status"] == "applied"
      assert result["cancelled_room_ids"] == ["room-a", "room-b"]
    end

    test "unpaid deposit for the selected rooms ceases to be due", %{conn: conn} do
      result = cancel_rooms(conn)

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      data = group_data(conn, "group-81")
      assert data["deposit_due_cents"] == 10500
      assert data["deposit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 10500
    end

    test "retains cash for a non-refundable settlement", %{conn: conn} do
      pay_group(conn, "group-81", 19500)

      result = cancel_rooms(conn, %{"occurred_on" => "2026-11-27"})

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 9000
      assert result["credit_issued_cents"] == 0

      ledger = ledger_data(conn)
      assert ledger["cash_held_cents"] == 10500
      assert ledger["cash_retained_cents"] == 9000
    end

    test "computes the hotel-credit bonus once on the combined cash", %{conn: conn} do
      # Per-room deposits are 6002 and 6003; separate per-room bonuses would
      # round to 600 + 600, while one bonus on 12005 rounds to 1201.
      open_group_fixture(conn, %{
        "operation_id" => "op-1002",
        "group_id" => "group-90",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10003},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10005}
        ]
      })

      pay_group(conn, "group-90", 12005)

      result =
        cancel_rooms(conn, %{
          "group_id" => "group-90",
          "room_ids" => ["room-a", "room-b"],
          "refund_method" => "hotel_credit"
        })

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 13206

      assert guest_credit_data(conn, "guest-22")["available_cents"] == 13206
      assert ledger_data(conn)["cash_converted_to_credit_cents"] == 12005
    end

    test "issues no lot when the selected rooms held no cash", %{conn: conn} do
      result = cancel_rooms(conn, %{"refund_method" => "hotel_credit"})

      assert result["status"] == "applied"
      assert result["credit_issued_cents"] == 0
      assert guest_credit_data(conn, "guest-22")["lots"] == []
    end

    test "restores credit funding the selected rooms to its original lot", %{conn: conn} do
      open_group_fixture(conn, %{
        "operation_id" => "op-open-fund",
        "group_id" => "group-fund",
        "occurred_on" => "2026-10-03"
      })

      pay_group(conn, "group-fund", 5000)
      cancel_group(conn, "group-fund", "2026-11-26", %{"refund_method" => "hotel_credit"})

      submit_batch(conn, [
        %{
          "operation_id" => "op-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-81",
          "amount_cents" => 3000
        }
      ])

      result = cancel_rooms(conn)

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0

      assert guest_credit_data(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-group-fund",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      assert ledger_data(conn)["credit_liability_cents"] == 5500
    end

    test "the group becomes cancelled when no active rooms remain", %{conn: conn} do
      pay_group(conn, "group-81", 19500)

      first = cancel_rooms(conn)
      assert first["status"] == "applied"
      assert group_data(conn, "group-81")["status"] == "active"

      second =
        cancel_rooms(conn, %{
          "operation_id" => "op-cancel-rooms-2",
          "room_ids" => ["room-b"]
        })

      assert second["status"] == "applied"
      assert second["refunded_cents"] == 10500
      assert second["revision"] == 4

      data = group_data(conn, "group-81")
      assert data["status"] == "cancelled"
      assert data["deposit_due_cents"] == 0
      assert data["deposit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0
    end

    test "cancel_group settles only the remaining active rooms", %{conn: conn} do
      pay_group(conn, "group-81", 19500)
      cancel_rooms(conn)

      result = cancel_group(conn, "group-81", "2026-11-26")

      assert result == %{
               "operation_id" => "op-cancel-group-81",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 10500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      data = group_data(conn, "group-81")
      assert data["status"] == "cancelled"

      assert ledger_data(conn)["cash_refunded_cents"] == 19500
      assert ledger_data(conn)["cash_held_cents"] == 0
    end
  end

  describe "rejections" do
    test "rejects room identifiers that do not identify distinct active rooms", %{conn: conn} do
      cancel_rooms(conn)

      operations = [
        cancel_rooms_op(%{"operation_id" => "op-unknown", "room_ids" => ["room-x"]}),
        cancel_rooms_op(%{"operation_id" => "op-other-group", "room_ids" => ["room-99"]}),
        cancel_rooms_op(%{
          "operation_id" => "op-duplicate",
          "room_ids" => ["room-b", "room-b"]
        }),
        cancel_rooms_op(%{"operation_id" => "op-cancelled", "room_ids" => ["room-a"]}),
        cancel_rooms_op(%{"operation_id" => "op-empty", "room_ids" => []}),
        cancel_rooms_op(%{"operation_id" => "op-not-ids", "room_ids" => [7]})
      ]

      %{"results" => results} = submit_batch(conn, operations)

      assert Enum.all?(results, &(&1["status"] == "rejected"))
      assert Enum.all?(results, &(&1["code"] == "invalid_rooms"))

      data = group_data(conn, "group-81")
      assert data["revision"] == 2
      assert room_by_id(data, "room-b")["status"] == "active"
    end

    test "rejects the complete operation when any room is invalid", %{conn: conn} do
      pay_group(conn, "group-81", 19500)

      result = cancel_rooms(conn, %{"room_ids" => ["room-a", "room-x"]})

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_rooms"

      data = group_data(conn, "group-81")
      assert room_by_id(data, "room-a")["status"] == "active"
      assert ledger_data(conn)["cash_refunded_cents"] == 0
    end

    test "rejects hotel credit for a non-refundable settlement", %{conn: conn} do
      pay_group(conn, "group-81", 19500)

      result =
        cancel_rooms(conn, %{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})

      assert result == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "rejected",
               "code" => "refund_method_not_available",
               "group_id" => "group-81"
             }

      data = group_data(conn, "group-81")
      assert data["revision"] == 2
      assert room_by_id(data, "room-a")["status"] == "active"
    end

    test "rejects cancelling rooms in a cancelled group", %{conn: conn} do
      cancel_group(conn, "group-81", "2026-11-26")

      result = cancel_rooms(conn)

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"
    end

    test "rejects a missing group", %{conn: conn} do
      result = cancel_rooms(conn, %{"group_id" => "group-404"})

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"
    end

    test "rejects a stale revision before room validation", %{conn: conn} do
      result =
        cancel_rooms(conn, %{"room_ids" => ["room-x"], "expected_revision" => 5})

      assert result["code"] == "stale_revision"
      assert result["expected_revision"] == 5
      assert result["actual_revision"] == 1
    end

    test "applies when the expected revision matches", %{conn: conn} do
      result = cancel_rooms(conn, %{"expected_revision" => 1})

      assert result["status"] == "applied"
      assert result["revision"] == 2
    end
  end

  describe "durable idempotency" do
    test "a retry returns the stored result without settling again", %{conn: conn} do
      pay_group(conn, "group-81", 19500)

      %{"results" => [first]} = submit_batch(conn, [cancel_rooms_op()])
      %{"results" => [retry]} = submit_batch(conn, [cancel_rooms_op()])

      assert retry == first

      assert ledger_data(conn)["cash_refunded_cents"] == 9000
      assert group_data(conn, "group-81")["revision"] == 3
    end

    test "a conflicting payload under the same identifier is rejected", %{conn: conn} do
      %{"results" => [applied]} = submit_batch(conn, [cancel_rooms_op()])
      assert applied["status"] == "applied"

      %{"results" => [result]} =
        submit_batch(conn, [cancel_rooms_op(%{"room_ids" => ["room-b"]})])

      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"

      data = group_data(conn, "group-81")
      assert room_by_id(data, "room-a")["status"] == "cancelled"
      assert room_by_id(data, "room-b")["status"] == "active"
    end
  end
end
