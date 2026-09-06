defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
  end

  defp room_by_id(data, room_id) do
    Enum.find(data["rooms"], &(&1["room_id"] == room_id))
  end

  describe "room fields" do
    test "exposes status and deposit accounting on every room", %{conn: conn} do
      data = group_data(conn, "group-81")

      assert room_by_id(data, "room-a") == %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 15000,
               "status" => "active",
               "deposit_due_cents" => 9000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }

      assert room_by_id(data, "room-b") == %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 17500,
               "status" => "active",
               "deposit_due_cents" => 10500,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
    end

    test "advance purchase rooms require their full lodging amount", %{conn: conn} do
      open_group_fixture(conn, %{
        "operation_id" => "op-1002",
        "group_id" => "group-90",
        "rate_plan" => "advance_purchase"
      })

      data = group_data(conn, "group-90")
      assert room_by_id(data, "room-a")["deposit_due_cents"] == 45000
      assert room_by_id(data, "room-b")["deposit_due_cents"] == 52500
    end
  end

  describe "fill order" do
    test "cash fills rooms in their original order", %{conn: conn} do
      pay_group(conn, "group-81", 10000)

      data = group_data(conn, "group-81")
      assert room_by_id(data, "room-a")["cash_paid_cents"] == 9000
      assert room_by_id(data, "room-b")["cash_paid_cents"] == 1000
    end

    test "credit from several lots can cross room boundaries and restores per lot", %{
      conn: conn
    } do
      open_group_fixture(conn, %{
        "operation_id" => "op-open-3",
        "group_id" => "group-3",
        "rooms" => [
          %{"room_id" => "room-1", "nightly_rate_cents" => 1000},
          %{"room_id" => "room-2", "nightly_rate_cents" => 1000},
          %{"room_id" => "room-3", "nightly_rate_cents" => 1000}
        ]
      })

      for suffix <- ["a", "b"] do
        open_group_fixture(conn, %{
          "operation_id" => "op-open-fund-#{suffix}",
          "group_id" => "group-fund-#{suffix}",
          "occurred_on" => "2026-10-03"
        })

        pay_group(conn, "group-fund-#{suffix}", 500)

        cancel_group(conn, "group-fund-#{suffix}", "2026-11-26", %{
          "refund_method" => "hotel_credit"
        })
      end

      # room-1's 600 deposit is paid in cash; rooms 2 and 3 remain.
      pay_group(conn, "group-3", 600)

      submit_batch(conn, [
        %{
          "operation_id" => "op-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-3",
          "amount_cents" => 1100
        }
      ])

      data = group_data(conn, "group-3")
      # Lot a (550) fills room-2 to 550, then lot b covers room-2's last 50
      # and room-3's 500.
      assert room_by_id(data, "room-2")["credit_paid_cents"] == 600
      assert room_by_id(data, "room-3")["credit_paid_cents"] == 500

      # Cancelling room-2 restores each portion to its own lot.
      submit_batch(conn, [
        %{
          "operation_id" => "op-cancel-room-2",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-3",
          "room_ids" => ["room-2"]
        }
      ])

      lots =
        guest_credit_data(conn, "guest-22")["lots"]
        |> Enum.map(&{&1["source_operation_id"], &1["remaining_cents"]})

      # Lot b still holds the 500 applied to room-3.
      assert lots == [
               {"op-cancel-group-fund-a", 550},
               {"op-cancel-group-fund-b", 50}
             ]
    end

    test "new funding continues where earlier funding stopped", %{conn: conn} do
      pay_group(conn, "group-81", 9500)

      pay_group(conn, "group-81", 500, %{
        "operation_id" => "op-pay-again",
        "amount_cents" => 500
      })

      data = group_data(conn, "group-81")
      assert room_by_id(data, "room-a")["cash_paid_cents"] == 9000
      assert room_by_id(data, "room-b")["cash_paid_cents"] == 1000
    end

    test "credit fills rooms in their original order after cash", %{conn: conn} do
      open_group_fixture(conn, %{
        "operation_id" => "op-open-fund",
        "group_id" => "group-fund",
        "occurred_on" => "2026-10-03"
      })

      pay_group(conn, "group-fund", 5000)
      cancel_group(conn, "group-fund", "2026-11-26", %{"refund_method" => "hotel_credit"})

      pay_group(conn, "group-81", 9000)

      submit_batch(conn, [
        %{
          "operation_id" => "op-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-81",
          "amount_cents" => 4000
        }
      ])

      data = group_data(conn, "group-81")
      assert room_by_id(data, "room-a")["cash_paid_cents"] == 9000
      assert room_by_id(data, "room-a")["credit_paid_cents"] == 0
      assert room_by_id(data, "room-b")["cash_paid_cents"] == 0
      assert room_by_id(data, "room-b")["credit_paid_cents"] == 4000
    end
  end

  describe "group totals" do
    test "totals describe active rooms only after rooms are cancelled", %{conn: conn} do
      pay_group(conn, "group-81", 19500)

      submit_batch(conn, [
        %{
          "operation_id" => "op-cancel-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81",
          "room_ids" => ["room-a"]
        }
      ])

      data = group_data(conn, "group-81")
      assert data["status"] == "active"
      assert data["lodging_total_cents"] == 52500
      assert data["deposit_due_cents"] == 10500
      assert data["deposit_paid_cents"] == 10500
      assert data["cash_paid_cents"] == 10500
      assert data["credit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0

      # The cancelled room keeps its historical accounting.
      room = room_by_id(data, "room-a")
      assert room["status"] == "cancelled"
      assert room["deposit_due_cents"] == 9000
      assert room["cash_paid_cents"] == 9000
    end

    test "funding still applies to the remaining active rooms", %{conn: conn} do
      submit_batch(conn, [
        %{
          "operation_id" => "op-cancel-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81",
          "room_ids" => ["room-a"]
        }
      ])

      result = pay_group(conn, "group-81", 10500)
      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 0

      data = group_data(conn, "group-81")
      assert room_by_id(data, "room-b")["cash_paid_cents"] == 10500

      overpay = pay_group(conn, "group-81", 1, %{"operation_id" => "op-pay-over"})
      assert overpay["status"] == "rejected"
      assert overpay["code"] == "payment_exceeds_outstanding"
    end
  end
end
