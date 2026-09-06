defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  defp post_batch(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(payload))
  end

  defp submit(conn, operations) do
    conn
    |> post_batch(%{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit_one(conn, operation) do
    [result] = submit(conn, [operation])
    result
  end

  # Flexible group, 3 nights: room-a lodging 45000 (due 9000), room-b
  # lodging 52500 (due 10500); the deposit due is 19500.
  defp open_operation(overrides) do
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

  defp open_group!(conn, overrides \\ %{}) do
    result = submit_one(conn, open_operation(overrides))
    assert result["status"] == "applied"
    result
  end

  defp pay!(conn, operation_id, group_id, amount_cents) do
    result =
      submit_one(conn, %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      })

    assert result["status"] == "applied"
    result
  end

  # Issues a credit lot for guest-22 by opening a group, funding it with
  # cash, and cancelling it refundably with refund_method hotel_credit.
  defp issue_credit!(conn, group_id, cash_cents) do
    open_group!(conn, %{"operation_id" => "op-open-#{group_id}", "group_id" => group_id})
    pay!(conn, "op-pay-#{group_id}", group_id, cash_cents)

    result =
      submit_one(conn, %{
        "operation_id" => "op-cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      })

    assert result["status"] == "applied"
    result
  end

  defp apply_credit!(conn, operation_id, group_id, amount_cents) do
    result =
      submit_one(conn, %{
        "operation_id" => operation_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-01",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      })

    assert result["status"] == "applied"
    result
  end

  defp cancel_rooms_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "room_ids" => ["room-b"]
      },
      overrides
    )
  end

  defp get_group(conn, group_id) do
    conn |> get(~p"/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp room(data, room_id) do
    Enum.find(data["rooms"], &(&1["room_id"] == room_id))
  end

  defp ledger(conn, on) do
    conn
    |> get(~p"/api/v1/ledger?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id, on) do
    conn
    |> get(~p"/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  describe "room accounting" do
    test "cash funds active room deposits in the rooms' original order", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      data = get_group(conn, "group-81")

      assert room(data, "room-a") == %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 15000,
               "status" => "active",
               "deposit_due_cents" => 9000,
               "cash_paid_cents" => 9000,
               "credit_paid_cents" => 0
             }

      assert room(data, "room-b") == %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 17500,
               "status" => "active",
               "deposit_due_cents" => 10500,
               "cash_paid_cents" => 1000,
               "credit_paid_cents" => 0
             }

      assert data["deposit_paid_cents"] == 10000
      assert data["outstanding_deposit_cents"] == 9500
    end

    test "later funding continues filling where earlier funding stopped", %{conn: conn} do
      issue_credit!(conn, "group-source", 10000)
      open_group!(conn)

      pay!(conn, "op-pay-1", "group-81", 9500)
      apply_credit!(conn, "op-apply", "group-81", 5000)
      pay!(conn, "op-pay-2", "group-81", 3000)

      data = get_group(conn, "group-81")

      # room-a: 9000 cash from op-pay-1; room-b: 500 from op-pay-1, then
      # 5000 credit, then 3000 cash from op-pay-2
      assert room(data, "room-a")["cash_paid_cents"] == 9000
      assert room(data, "room-a")["credit_paid_cents"] == 0
      assert room(data, "room-b")["cash_paid_cents"] == 3500
      assert room(data, "room-b")["credit_paid_cents"] == 5000

      assert data["deposit_paid_cents"] == 17500
      assert data["cash_paid_cents"] == 12500
      assert data["credit_paid_cents"] == 5000
      assert data["outstanding_deposit_cents"] == 2000
    end
  end

  describe "cancel_rooms" do
    test "settles the selected rooms and leaves other rooms unchanged", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      assert submit_one(conn, cancel_rooms_operation()) == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 1000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      data = get_group(conn, "group-81")

      assert data["status"] == "active"
      assert data["lodging_total_cents"] == 45000
      assert data["deposit_due_cents"] == 9000
      assert data["deposit_paid_cents"] == 9000
      assert data["outstanding_deposit_cents"] == 0

      assert room(data, "room-a")["status"] == "active"
      assert room(data, "room-a")["cash_paid_cents"] == 9000

      assert room(data, "room-b") == %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 17500,
               "status" => "cancelled",
               "deposit_due_cents" => 10500,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }

      assert ledger(conn, "2026-11-26")["cash_refunded_cents"] == 1000
      assert ledger(conn, "2026-11-26")["cash_held_cents"] == 9000
    end

    test "cancelled_room_ids come back in the group's original room order", %{conn: conn} do
      open_group!(conn, %{
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 100},
          %{"room_id" => "room-b", "nightly_rate_cents" => 200},
          %{"room_id" => "room-c", "nightly_rate_cents" => 300}
        ]
      })

      result =
        submit_one(conn, cancel_rooms_operation(%{"room_ids" => ["room-c", "room-a"]}))

      assert result["status"] == "applied"
      assert result["cancelled_room_ids"] == ["room-a", "room-c"]

      data = get_group(conn, "group-81")
      assert Enum.map(data["rooms"], & &1["status"]) == ["cancelled", "active", "cancelled"]
      assert data["status"] == "active"
    end

    test "unpaid deposit for the selected rooms is simply no longer due", %{conn: conn} do
      open_group!(conn)

      result = submit_one(conn, cancel_rooms_operation(%{"room_ids" => ["room-a"]}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      data = get_group(conn, "group-81")
      assert data["deposit_due_cents"] == 10500
      assert data["outstanding_deposit_cents"] == 10500
    end

    test "cancelling the last active room cancels the group", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 19500)

      submit_one(conn, cancel_rooms_operation(%{"room_ids" => ["room-a"]}))

      result =
        submit_one(
          conn,
          cancel_rooms_operation(%{"operation_id" => "op-cancel-last", "room_ids" => ["room-b"]})
        )

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 10500

      data = get_group(conn, "group-81")
      assert data["status"] == "cancelled"

      # the group behaves like any cancelled group afterwards
      later =
        submit_one(conn, %{
          "operation_id" => "op-pay-late",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-81",
          "amount_cents" => 100
        })

      assert later["code"] == "group_not_active"
    end

    test "cancel_group after a partial cancellation settles only the remaining rooms", %{
      conn: conn
    } do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 19500)

      submit_one(conn, cancel_rooms_operation(%{"room_ids" => ["room-a"]}))

      result =
        submit_one(conn, %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81"
        })

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 10500
      assert result["retained_cents"] == 0

      assert get_group(conn, "group-81")["status"] == "cancelled"
      assert ledger(conn, "2026-11-26")["cash_refunded_cents"] == 19500
    end

    test "a non-refundable partial cancellation retains the rooms' cash and consumes credit", %{
      conn: conn
    } do
      issue_credit!(conn, "group-source", 10000)
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)
      apply_credit!(conn, "op-apply", "group-81", 5000)

      # 12 days before arrival: inside the 14-day window
      result =
        submit_one(conn, cancel_rooms_operation(%{"occurred_on" => "2026-11-28"}))

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 1000
      assert result["credit_issued_cents"] == 0

      # room-b's credit is consumed; the unapplied remainder of the lot is untouched
      assert guest_credit(conn, "guest-22", "2026-11-28")["available_cents"] == 6000
      assert ledger(conn, "2026-11-28")["credit_liability_cents"] == 6000
      assert ledger(conn, "2026-11-28")["cash_retained_cents"] == 1000

      data = get_group(conn, "group-81")
      assert room(data, "room-a")["cash_paid_cents"] == 9000
    end

    test "a refundable partial cancellation restores applied credit to its lot", %{conn: conn} do
      issue_credit!(conn, "group-source", 10000)
      open_group!(conn)
      apply_credit!(conn, "op-apply", "group-81", 10000)

      result = submit_one(conn, cancel_rooms_operation())

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["credit_issued_cents"] == 0

      # room-b held 1000 cash? no: 10000 credit fills room-a 9000 + room-b
      # 1000; cancelling room-b restores its 1000 to the lot
      assert guest_credit(conn, "guest-22", "2026-11-26") == %{
               "guest_id" => "guest-22",
               "available_cents" => 2000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-group-source",
                   "remaining_cents" => 2000,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      assert ledger(conn, "2026-11-26")["credit_liability_cents"] == 11000

      data = get_group(conn, "group-81")
      assert room(data, "room-a")["credit_paid_cents"] == 9000
      assert room(data, "room-b")["credit_paid_cents"] == 0
    end

    test "hotel_credit converts the selected rooms' combined cash with one bonus", %{conn: conn} do
      # one night; room-a due 5, room-b due 25
      open_group!(conn, %{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 25},
          %{"room_id" => "room-b", "nightly_rate_cents" => 125}
        ]
      })

      pay!(conn, "op-pay", "group-81", 10)

      result =
        submit_one(
          conn,
          cancel_rooms_operation(%{
            "room_ids" => ["room-a", "room-b"],
            "refund_method" => "hotel_credit"
          })
        )

      # the 10% bonus on the combined 10 cents is exactly 1; computed per
      # room it would round 0.5 up twice and issue 12
      assert result["credit_issued_cents"] == 11
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      assert guest_credit(conn, "guest-22", "2026-11-26")["available_cents"] == 11
      assert ledger(conn, "2026-11-26")["cash_converted_to_credit_cents"] == 10
    end

    test "hotel_credit is rejected when the cancellation is non-refundable", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      result =
        submit_one(
          conn,
          cancel_rooms_operation(%{
            "occurred_on" => "2026-11-28",
            "refund_method" => "hotel_credit"
          })
        )

      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"

      data = get_group(conn, "group-81")
      assert data["status"] == "active"
      assert data["revision"] == 2
      assert room(data, "room-b")["status"] == "active"
      assert room(data, "room-b")["cash_paid_cents"] == 1000
    end

    test "rejects room identifiers that are not distinct active rooms of the group", %{
      conn: conn
    } do
      open_group!(conn)
      submit_one(conn, cancel_rooms_operation(%{"operation_id" => "op-pre"}))

      for {room_ids, n} <-
            Enum.with_index([
              ["room-b", "room-b"],
              ["room-missing"],
              ["room-b"],
              ["room-a", "group-81"],
              [],
              "room-a",
              [nil],
              [42]
            ]) do
        result =
          submit_one(
            conn,
            cancel_rooms_operation(%{"operation_id" => "op-bad-#{n}", "room_ids" => room_ids})
          )

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_rooms"
      end

      # nothing was settled
      data = get_group(conn, "group-81")
      assert data["status"] == "active"
      assert room(data, "room-a")["status"] == "active"
    end

    test "rejects missing groups, cancelled groups, and stale revisions", %{conn: conn} do
      result = submit_one(conn, cancel_rooms_operation())
      assert result["code"] == "group_not_found"

      open_group!(conn)

      submit_one(conn, %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      })

      result =
        submit_one(conn, cancel_rooms_operation(%{"operation_id" => "op-cancel-rooms-2"}))

      assert result["code"] == "group_not_active"
    end

    test "a stale revision is rejected before the rooms are validated", %{conn: conn} do
      open_group!(conn)

      result =
        submit_one(
          conn,
          cancel_rooms_operation(%{"room_ids" => ["bogus"], "expected_revision" => 99})
        )

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "group-81"
      assert result["actual_revision"] == 1
    end

    test "an exact retry returns the original result without settling twice", %{conn: conn} do
      open_group!(conn)
      pay!(conn, "op-pay", "group-81", 10000)

      original = submit_one(conn, cancel_rooms_operation())
      assert submit_one(conn, cancel_rooms_operation()) == original

      data = get_group(conn, "group-81")
      assert data["revision"] == 3
      assert ledger(conn, "2026-11-26")["cash_refunded_cents"] == 1000
    end
  end
end
