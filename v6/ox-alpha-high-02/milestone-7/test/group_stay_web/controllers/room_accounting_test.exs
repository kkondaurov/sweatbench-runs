defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  @booked_on "2026-10-03"

  describe "room-level accounting" do
    test "cash funds active rooms in original order, one deposit at a time", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 10_000)])

      group = get_group(conn, "group-81")

      assert Enum.map(group["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) ==
               [{"room-a", 9_000}, {"room-b", 1_000}]

      assert group["deposit_paid_cents"] == 10_000
      assert group["outstanding_deposit_cents"] == 9_500
      assert ledger(conn)["cash_held_cents"] == 10_000
    end

    test "credit continues filling where cash stopped", %{conn: conn} do
      issue_credit(conn, "op-cancel-17", "group-src", 10_000, "2026-11-26")
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay", "group-81", 9_000)])
      submit(conn, [credit_op("op-use", "group-81", 2_000)])

      group = get_group(conn, "group-81")

      assert Enum.map(
               group["rooms"],
               &{&1["room_id"], &1["cash_paid_cents"], &1["credit_paid_cents"]}
             ) ==
               [{"room-a", 9_000, 0}, {"room-b", 0, 2_000}]

      # the funded credit neither expires nor appears as available
      assert guest_credit(conn, "guest-22")["available_cents"] == 9_000
      assert ledger(conn)["credit_liability_cents"] == 11_000
    end

    test "later funding allocates in operation-processing order after earlier gaps", %{conn: conn} do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-pay-1", "group-81", 4_000)])
      submit(conn, [payment_op("op-pay-2", "group-81", 8_000)])

      # op-pay-1 took 4_000 of room-a; op-pay-2 filled room-a (5_000) and
      # started room-b (3_000)
      assert Enum.map(get_group(conn, "group-81")["rooms"], & &1["cash_paid_cents"]) ==
               [9_000, 3_000]
    end
  end

  describe "cancel_rooms" do
    setup :funded_two_room_group

    test "settles only the selected rooms and reports them in original room order", %{
      conn: conn
    } do
      result =
        only_result(
          submit(conn, [cancel_rooms_op("op-cr", "group-81", ["room-b"], "2026-11-26")])
        )

      assert result == %{
               "operation_id" => "op-cr",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 3_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      group = get_group(conn, "group-81")

      # totals describe the remaining active rooms only
      assert group["status"] == "active"
      assert group["lodging_total_cents"] == 45_000
      assert group["deposit_due_cents"] == 9_000
      assert group["deposit_paid_cents"] == 9_000
      assert group["outstanding_deposit_cents"] == 0

      [room_a, room_b] = group["rooms"]
      assert room_a["status"] == "active"
      assert room_a["cash_paid_cents"] == 9_000
      assert room_b["status"] == "cancelled"
      assert room_b["cash_paid_cents"] == 0

      assert ledger(conn)["cash_held_cents"] == 9_000
      assert ledger(conn)["cash_refunded_cents"] == 3_000
    end

    test "returns cancelled rooms in group order regardless of submission order", %{conn: conn} do
      result =
        only_result(
          submit(conn, [
            cancel_rooms_op("op-cr", "group-81", ["room-b", "room-a"], "2026-11-26")
          ])
        )

      assert result["cancelled_room_ids"] == ["room-a", "room-b"]
      assert result["refunded_cents"] == 12_000

      # no active rooms remain, so the whole group is cancelled
      assert get_group(conn, "group-81")["status"] == "cancelled"
      assert get_group(conn, "group-81")["deposit_due_cents"] == 0
      assert get_group(conn, "group-81")["outstanding_deposit_cents"] == 0
    end

    test "rejects anything that is not a set of distinct active rooms", %{conn: conn} do
      for {room_ids, index} <-
            Enum.with_index([
              ["room-a", "room-a"],
              ["room-a", "room-zz"],
              [],
              ["room-a", "ROOM-A"]
            ]) do
        op = cancel_rooms_op("op-bad-#{index}", "group-81", room_ids, "2026-11-26")

        assert rejection(submit(conn, [op]), "invalid_rooms")
      end

      # an already cancelled room can no longer be selected
      submit(conn, [cancel_rooms_op("op-first", "group-81", ["room-a"], "2026-11-26")])

      assert rejection(
               submit(conn, [cancel_rooms_op("op-again", "group-81", ["room-a"], "2026-11-26")]),
               "invalid_rooms"
             )

      assert get_group(conn, "group-81")["revision"] == 4
    end

    test "computes the hotel-credit bonus once on the combined cash", %{conn: conn} do
      # room-a holds exactly 5 cents of cash; room-b holds 5 more from the
      # second payment. Separately rounded bonuses would pay 6 + 6.
      apply_open!(conn, "group-tiny",
        rooms: [
          %{"room_id" => "room-a", "nightly_rate_cents" => 8},
          %{"room_id" => "room-b", "nightly_rate_cents" => 15_000}
        ]
      )

      submit(conn, [payment_op("op-tiny-1", "group-tiny", 5)])
      submit(conn, [payment_op("op-tiny-2", "group-tiny", 5)])

      result =
        only_result(
          submit(conn, [
            cancel_rooms_op("op-cr", "group-tiny", ["room-a", "room-b"], "2026-11-26")
            |> Map.put("refund_method", "hotel_credit")
          ])
        )

      # bonus(10) = 11, not bonus(5) + bonus(5) = 12
      assert result["credit_issued_cents"] == 11
      assert guest_credit(conn, "guest-22")["available_cents"] == 11
    end

    test "a non-refundable partial cancellation retains the selected cash", %{conn: conn} do
      apply_open!(conn, "group-ap", rate_plan: "advance_purchase")
      submit(conn, [payment_op("op-ap-1", "group-ap", 90_000)])
      submit(conn, [payment_op("op-ap-2", "group-ap", 7_500)])

      result =
        only_result(
          submit(conn, [cancel_rooms_op("op-cr", "group-ap", ["room-a"], "2026-10-05")])
        )

      # room-a holds 45_000 of the first payment
      assert result["retained_cents"] == 45_000
      assert result["refunded_cents"] == 0

      group = get_group(conn, "group-ap")
      assert group["status"] == "active"
      assert Enum.find(group["rooms"], &(&1["room_id"] == "room-b"))["cash_paid_cents"] == 52_500
      assert ledger(conn)["cash_retained_cents"] == 45_000
    end

    test "hotel credit is refused for a non-refundable selection", %{conn: conn} do
      apply_open!(conn, "group-ap", rate_plan: "advance_purchase")
      submit(conn, [payment_op("op-ap", "group-ap", 90_000)])

      op =
        cancel_rooms_op("op-cr", "group-ap", ["room-a"], "2026-10-05")
        |> Map.put("refund_method", "hotel_credit")

      assert rejection(submit(conn, [op]), "refund_method_not_available")

      group = get_group(conn, "group-ap")
      assert group["status"] == "active"
      assert group["revision"] == 2
    end

    test "cancel_group afterwards settles only the remaining active rooms", %{conn: conn} do
      submit(conn, [cancel_rooms_op("op-cr", "group-81", ["room-b"], "2026-11-26")])

      result = only_result(submit(conn, [cancel_op("op-cancel", "group-81", "2026-11-26")]))

      assert result["refunded_cents"] == 9_000
      assert get_group(conn, "group-81")["status"] == "cancelled"
      assert ledger(conn)["cash_refunded_cents"] == 12_000
    end

    test "restores applied credit for the selected rooms to its lots", %{conn: conn} do
      issue_credit(conn, "op-cancel-17", "group-src", 10_000, "2026-11-26")
      apply_open!(conn, "group-solo")
      submit(conn, [payment_op("op-pay", "group-solo", 9_000)])
      submit(conn, [credit_op("op-use", "group-solo", 2_500)])

      result =
        only_result(
          submit(conn, [cancel_rooms_op("op-cr", "group-solo", ["room-b"], "2026-11-26")])
        )

      # room-b held no cash but 2_500 of the applied credit; it returns to its
      # lot without a second bonus and nothing is refunded or retained
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      group = get_group(conn, "group-solo")
      assert group["deposit_due_cents"] == 9_000
      assert group["credit_paid_cents"] == 0
      assert group["cash_paid_cents"] == 9_000

      assert guest_credit(conn, "guest-22")["available_cents"] == 11_000
      assert ledger(conn)["credit_liability_cents"] == 11_000
    end

    test "follows the revision contract", %{conn: conn} do
      stale =
        cancel_rooms_op("op-stale", "group-81", ["room-b"], "2026-11-26")
        |> Map.put("expected_revision", 99)

      assert rejection(submit(conn, [stale]), "stale_revision")
      assert get_group(conn, "group-81")["revision"] == 3

      current =
        cancel_rooms_op("op-current", "group-81", ["room-b"], "2026-11-26")
        |> Map.put("expected_revision", 3)

      assert only_result(submit(conn, [current]))["revision"] == 4
    end
  end

  # Helpers

  defp funded_two_room_group(%{conn: conn}) do
    apply_open!(conn, "group-81")
    submit(conn, [payment_op("op-pay-1", "group-81", 5_000)])
    submit(conn, [payment_op("op-pay-2", "group-81", 7_000)])

    # room-a holds op-pay-1 (5_000) and 4_000 of op-pay-2; room-b holds 3_000
    # of op-pay-2
    {:ok, conn: conn}
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp only_result(response) do
    [result] = response["results"]
    result
  end

  defp rejection(response, code) do
    result = only_result(response)

    result["status"] == "rejected" and result["code"] == code
  end

  defp apply_open!(conn, group_id, opts \\ []) do
    result = only_result(submit(conn, [open_op(group_id, opts)]))
    assert result["status"] == "applied"
    result
  end

  defp open_op(group_id, opts) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-" <> group_id),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => Keyword.get(opts, :arrival_on, "2026-12-10"),
      "departure_on" => Keyword.get(opts, :departure_on, "2026-12-13"),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" =>
        Keyword.get(opts, :rooms, [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ])
    }
  end

  defp payment_op(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => @booked_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp cancel_rooms_op(operation_id, group_id, room_ids, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "room_ids" => room_ids
    }
  end

  defp credit_op(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => @booked_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp issue_credit(conn, operation_id, group_id, cash_cents, occurred_on) do
    apply_open!(conn, group_id)

    if cash_cents > 0 do
      submit(conn, [payment_op("op-pay-" <> group_id, group_id, cash_cents)])
    end

    result =
      only_result(
        submit(conn, [
          cancel_op(operation_id, group_id, occurred_on)
          |> Map.put("refund_method", "hotel_credit")
        ])
      )

    assert result["status"] == "applied"
    result
  end

  defp get_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id) do
    conn |> get("/api/v1/guests/#{guest_id}/credit") |> json_response(200) |> Map.fetch!("data")
  end
end
