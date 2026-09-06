defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, op) do
    resp = post(conn, "/api/v1/partner-batches", %{"operations" => [op]})
    Jason.decode!(resp.resp_body)["results"] |> hd()
  end

  defp open(conn, group_id, opts \\ []) do
    arrival_on = Keyword.get(opts, :arrival_on, "2026-12-10")

    rooms =
      Keyword.get(
        opts,
        :rooms,
        for(id <- ~w(room-a room-b), do: %{"room_id" => id, "nightly_rate_cents" => 10_000})
      )

    submit(conn, %{
      "operation_id" => Keyword.get(opts, :operation_id, "open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :booked_on, "2026-10-03"),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, "guest-22"),
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => arrival_on |> Date.from_iso8601!() |> Date.add(3) |> Date.to_iso8601(),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" => rooms
    })
  end

  defp pay(conn, group_id, amount_cents, opts \\ []) do
    submit(conn, %{
      "operation_id" => Keyword.get(opts, :operation_id, "pay-#{group_id}"),
      "type" => "record_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, "2026-10-04"),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    })
  end

  defp apply_credit(conn, group_id, amount_cents, occurred_on, opts \\ []) do
    submit(conn, %{
      "operation_id" => Keyword.get(opts, :operation_id, "credit-#{group_id}"),
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    })
  end

  defp cancel_rooms(conn, group_id, room_ids, occurred_on, opts \\ []) do
    op = %{
      "operation_id" => Keyword.get(opts, :operation_id, "cancel-rooms-#{group_id}"),
      "type" => "cancel_rooms",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "room_ids" => room_ids
    }

    op =
      case Keyword.fetch(opts, :refund_method) do
        {:ok, method} -> Map.put(op, "refund_method", method)
        :error -> op
      end

    op =
      case Keyword.fetch(opts, :expected_revision) do
        {:ok, revision} -> Map.put(op, "expected_revision", revision)
        :error -> op
      end

    submit(conn, op)
  end

  defp cancel_group(conn, group_id, occurred_on, opts) do
    op = %{
      "operation_id" => Keyword.get(opts, :operation_id, "cancel-#{group_id}"),
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    op =
      case Keyword.fetch(opts, :refund_method) do
        {:ok, method} -> Map.put(op, "refund_method", method)
        :error -> op
      end

    submit(conn, op)
  end

  defp group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn, query \\ "") do
    conn |> get("/api/v1/ledger#{query}") |> json_response(200) |> Map.fetch!("data")
  end

  defp credit(conn, guest_id, query \\ "") do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit#{query}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp active_room(data, room_id) do
    Enum.find(data["rooms"], &(&1["room_id"] == room_id))
  end

  describe "room-level accounting" do
    test "funds rooms in original order and exposes per-room accounting", %{conn: conn} do
      open(conn, "group-rooms",
        rooms:
          for(
            id <- ~w(room-a room-b room-c),
            do: %{"room_id" => id, "nightly_rate_cents" => 10_000}
          )
      )

      data = group(conn, "group-rooms")

      assert Enum.map(data["rooms"], &{&1["room_id"], &1["deposit_due_cents"]}) == [
               {"room-a", 6_000},
               {"room-b", 6_000},
               {"room-c", 6_000}
             ]

      # Cash fills room-a fully, then spills into room-b.
      pay(conn, "group-rooms", 10_000)

      data = group(conn, "group-rooms")
      assert active_room(data, "room-a")["cash_paid_cents"] == 6_000
      assert active_room(data, "room-b")["cash_paid_cents"] == 4_000
      assert active_room(data, "room-c")["cash_paid_cents"] == 0
      assert data["deposit_paid_cents"] == 10_000
      assert data["cash_paid_cents"] == 10_000
      assert data["credit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 8_000

      # Build a hotel-credit lot for the guest.
      open(conn, "src-rooms", rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])

      pay(conn, "src-rooms", 5_500, operation_id: "pay-src")
      cancel_group(conn, "src-rooms", "2026-11-01", refund_method: "hotel_credit")

      # Credit continues filling the earliest room with remaining capacity.
      apply_credit(conn, "group-rooms", 5_500, "2027-01-10")

      data = group(conn, "group-rooms")
      assert active_room(data, "room-a")["cash_paid_cents"] == 6_000
      assert active_room(data, "room-a")["credit_paid_cents"] == 0
      assert active_room(data, "room-b")["cash_paid_cents"] == 4_000
      assert active_room(data, "room-b")["credit_paid_cents"] == 2_000
      assert active_room(data, "room-c")["credit_paid_cents"] == 3_500
      assert data["deposit_paid_cents"] == 15_500
      assert data["credit_paid_cents"] == 5_500
      assert data["outstanding_deposit_cents"] == 2_500

      assert Enum.map(data["rooms"], & &1["status"]) == ["active", "active", "active"]
    end
  end

  describe "cancel_rooms" do
    test "settles selected rooms refundably and leaves the others untouched", %{conn: conn} do
      open(conn, "group-part")
      pay(conn, "group-part", 12_000)

      result = cancel_rooms(conn, "group-part", ["room-b"], "2026-11-01")

      assert result == %{
               "operation_id" => "cancel-rooms-group-part",
               "status" => "applied",
               "group_id" => "group-part",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 6_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      data = group(conn, "group-part")
      assert data["status"] == "active"
      assert data["revision"] == 3
      assert data["lodging_total_cents"] == 30_000
      assert data["deposit_due_cents"] == 6_000
      assert data["deposit_paid_cents"] == 6_000
      assert data["cash_paid_cents"] == 6_000
      assert data["outstanding_deposit_cents"] == 0

      cancelled = active_room(data, "room-b")

      assert cancelled == %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 10_000,
               "status" => "cancelled",
               "deposit_due_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }

      remaining = active_room(data, "room-a")
      assert remaining["status"] == "active"
      assert remaining["cash_paid_cents"] == 6_000

      assert ledger(conn) == %{
               "cash_held_cents" => 6_000,
               "cash_refunded_cents" => 6_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "returns cancelled_room_ids in original room order regardless of input", %{conn: conn} do
      open(conn, "group-order")

      result = cancel_rooms(conn, "group-order", ["room-b", "room-a"], "2026-11-01")

      assert result["cancelled_room_ids"] == ["room-a", "room-b"]
      assert result["refunded_cents"] == 0
      assert result["revision"] == 2

      data = group(conn, "group-order")
      assert data["status"] == "cancelled"
      assert data["deposit_due_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0
    end

    test "rejects with invalid_rooms for unusable selections without settling", %{conn: conn} do
      open(conn, "group-bad-rooms")
      pay(conn, "group-bad-rooms", 6_000)

      open(conn, "group-other", rooms: [%{"room_id" => "room-x", "nightly_rate_cents" => 10_000}])

      assert cancel_rooms(conn, "group-bad-rooms", ["room-nope"], "2026-11-01",
               operation_id: "c1"
             )[
               "code"
             ] == "invalid_rooms"

      assert cancel_rooms(conn, "group-bad-rooms", ["room-a", "room-a"], "2026-11-01",
               operation_id: "c2"
             )[
               "code"
             ] == "invalid_rooms"

      # room-x belongs to another group.
      assert cancel_rooms(conn, "group-bad-rooms", ["room-x"], "2026-11-01", operation_id: "c9")[
               "code"
             ] == "invalid_rooms"

      assert cancel_rooms(conn, "group-bad-rooms", [], "2026-11-01", operation_id: "c3")["code"] ==
               "invalid_rooms"

      assert submit(conn, %{
               "operation_id" => "c4",
               "type" => "cancel_rooms",
               "occurred_on" => "2026-11-01",
               "group_id" => "group-bad-rooms"
             })["code"] == "invalid_operation"

      # The group, its funding, and the ledger are fully unchanged.
      data = group(conn, "group-bad-rooms")
      assert data["revision"] == 2
      assert data["cash_paid_cents"] == 6_000
      assert active_room(data, "room-a")["status"] == "active"
      assert ledger(conn)["cash_refunded_cents"] == 0

      # A partial cancellation invalidates the room for later selections.
      cancel_rooms(conn, "group-bad-rooms", ["room-a"], "2026-11-01", operation_id: "c5")

      assert cancel_rooms(conn, "group-bad-rooms", ["room-a"], "2026-11-01", operation_id: "c6")[
               "code"
             ] == "invalid_rooms"
    end

    test "rejects stale revisions before room validation", %{conn: conn} do
      open(conn, "group-stale-rooms")
      pay(conn, "group-stale-rooms", 1_000)

      result =
        cancel_rooms(conn, "group-stale-rooms", ["room-nope"], "2026-11-01",
          expected_revision: 1,
          operation_id: "c-stale"
        )

      assert result == %{
               "operation_id" => "c-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-stale-rooms",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "non-refundable cancel_rooms retains cash and consumes credit", %{conn: conn} do
      guest_id = "guest-retain-rooms"

      open(conn, "rooms-src",
        guest_id: guest_id,
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      pay(conn, "rooms-src", 5_000, operation_id: "pay-rooms-src")
      cancel_group(conn, "rooms-src", "2026-11-01", refund_method: "hotel_credit")

      open(conn, "rooms-to", guest_id: guest_id)
      pay(conn, "rooms-to", 6_000, operation_id: "pay-rooms-to")
      apply_credit(conn, "rooms-to", 2_000, "2026-11-20")
      assert ledger(conn)["credit_liability_cents"] == 5_500

      # 2026-12-01 is 9 days before arrival: inside the 14-day window.
      result = cancel_rooms(conn, "rooms-to", ["room-a", "room-b"], "2026-12-01")

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 6_000
      assert result["credit_issued_cents"] == 0

      data = group(conn, "rooms-to")
      assert data["status"] == "cancelled"
      assert data["cash_paid_cents"] == 0
      assert data["credit_paid_cents"] == 0

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 6_000,
               "cash_converted_to_credit_cents" => 5_000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 3_500,
               "credit_shortfall_cents" => 0
             }

      # The applied credit was consumed rather than restored.
      assert credit(conn, guest_id)["available_cents"] == 3_500
    end

    test "hotel credit bonuses the selected rooms' combined cash once", %{conn: conn} do
      guest_id = "guest-combined-bonus"

      open(conn, "rooms-bonus",
        guest_id: guest_id,
        rooms:
          for(
            id <- ~w(room-a room-b room-c),
            do: %{"room_id" => id, "nightly_rate_cents" => 10_000}
          )
      )

      pay(conn, "rooms-bonus", 4_000, operation_id: "bonus-p1")
      pay(conn, "rooms-bonus", 2_000, operation_id: "bonus-p2")

      result =
        cancel_rooms(conn, "rooms-bonus", ["room-c", "room-a"], "2026-11-01",
          refund_method: "hotel_credit"
        )

      assert result["cancelled_room_ids"] == ["room-a", "room-c"]
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      # Combined cash of the selected rooms: room-a's 4000 + room-b's 2000.
      # 6000 + 10% rounding = 6600, computed once.
      assert result["credit_issued_cents"] == 6_600

      assert credit(conn, guest_id) == %{
               "guest_id" => guest_id,
               "available_cents" => 6_600,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-rooms-rooms-bonus",
                   "remaining_cents" => 6_600,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }

      assert ledger(conn)["cash_converted_to_credit_cents"] == 6_000
    end

    test "refund_method_not_available for non-refundable hotel-credit requests", %{conn: conn} do
      open(conn, "rooms-late")
      pay(conn, "rooms-late", 1_000)

      result =
        cancel_rooms(conn, "rooms-late", ["room-a"], "2026-12-01", refund_method: "hotel_credit")

      assert result["code"] == "refund_method_not_available"
      assert group(conn, "rooms-late")["status"] == "active"
      assert group(conn, "rooms-late")["revision"] == 2
      assert ledger(conn)["cash_held_cents"] == 1_000
    end

    test "cancel_group later settles only the remaining active rooms", %{conn: conn} do
      open(conn, "rooms-rest")
      pay(conn, "rooms-rest", 12_000)
      cancel_rooms(conn, "rooms-rest", ["room-a"], "2026-11-01")

      assert ledger(conn)["cash_refunded_cents"] == 6_000

      result = cancel_group(conn, "rooms-rest", "2026-11-02", operation_id: "cancel-rest")

      assert result == %{
               "operation_id" => "cancel-rest",
               "status" => "applied",
               "group_id" => "rooms-rest",
               "refunded_cents" => 6_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      # Room-a's settlement was not repeated.
      assert ledger(conn)["cash_refunded_cents"] == 12_000
      assert group(conn, "rooms-rest")["status"] == "cancelled"
    end

    test "durable idempotency applies", %{conn: conn} do
      open(conn, "rooms-idem")
      pay(conn, "rooms-idem", 6_000)

      op = %{
        "operation_id" => "cancel-rooms-idem",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-01",
        "group_id" => "rooms-idem",
        "room_ids" => ["room-a"]
      }

      first = submit(conn, op)
      assert first["status"] == "applied"

      assert submit(conn, op) == first
      assert group(conn, "rooms-idem")["revision"] == 3
      assert ledger(conn)["cash_refunded_cents"] == 6_000
    end
  end
end
