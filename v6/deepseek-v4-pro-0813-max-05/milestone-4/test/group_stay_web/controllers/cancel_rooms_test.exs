defmodule GroupStayWeb.CancelRoomsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  # Opens the default group and funds it: room-a 9_000 cash (pay-1 fills
  # room-a) and 4_500 credit (pay-2 could be cash; use credit via apply).
  defp open_and_fund(conn) do
    open_group!(conn)

    json_post(
      conn,
      payment(%{"operation_id" => "pay-1", "amount_cents" => 9_000})
    )

    conn
  end

  describe "cancel_rooms" do
    test "settles only the selected rooms and leaves the rest untouched", %{conn: conn} do
      open_and_fund(conn)
      json_post(conn, payment(%{"operation_id" => "pay-2", "amount_cents" => 3_000}))

      # room-a holds 9_000, room-b holds 3_000.
      conn =
        json_post(
          conn,
          cancel_rooms(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-26"})
        )

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-cancel-rooms",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "cancelled_room_ids" => ["room-a"],
                   "refunded_cents" => 9_000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 4
                 }
               ]
             }

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]

      rooms_by_id = Map.new(data["rooms"], &{&1["room_id"], &1})
      assert rooms_by_id["room-a"]["status"] == "cancelled"
      assert rooms_by_id["room-b"]["status"] == "active"

      assert rooms_by_id["room-a"]["cash_paid_cents"] == 0
      assert rooms_by_id["room-b"]["cash_paid_cents"] == 3_000

      assert data["status"] == "active"
      assert data["deposit_due_cents"] == 10_500
      assert data["cash_paid_cents"] == 3_000
      assert data["outstanding_deposit_cents"] == 7_500
    end

    test "returns cancelled_room_ids in the group's original room order", %{conn: conn} do
      open_and_fund(conn)
      json_post(conn, payment(%{"operation_id" => "pay-2", "amount_cents" => 4_000}))

      conn =
        json_post(
          conn,
          cancel_rooms(%{"room_ids" => ["room-b", "room-a"], "occurred_on" => "2026-11-26"})
        )

      [result] = json_response(conn, 200)["results"]
      assert result["status"] == "applied"
      assert result["cancelled_room_ids"] == ["room-a", "room-b"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["status"] == "cancelled"
      assert Enum.map(data["rooms"], & &1["status"]) == ["cancelled", "cancelled"]
    end

    test "settles a non-refundable selection by retaining", %{conn: conn} do
      open_and_fund(conn)
      json_post(conn, payment(%{"operation_id" => "pay-2", "amount_cents" => 3_000}))

      conn =
        json_post(
          conn,
          cancel_rooms(%{"room_ids" => ["room-b"], "occurred_on" => "2026-12-01"})
        )

      [result] = json_response(conn, 200)["results"]
      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 3_000
      assert result["credit_issued_cents"] == 0

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_retained_cents"] == 3_000
      assert ledger["cash_held_cents"] == 9_000
    end

    test "computes the hotel-credit bonus once on the combined cash", %{conn: conn} do
      open_and_fund(conn)
      json_post(conn, payment(%{"operation_id" => "pay-2", "amount_cents" => 1_000}))

      conn =
        json_post(
          conn,
          cancel_rooms(%{
            "room_ids" => ["room-a", "room-b"],
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        )

      [result] = json_response(conn, 200)["results"]

      assert result == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-a", "room-b"],
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_000,
               "revision" => 4
             }

      # One lot for the combined 10_000, not one 9_900 and one 1_100.
      data = json_response(get(conn, guest_credit_path("guest-22")), 200)["data"]
      assert data["available_cents"] == 11_000

      assert [
               %{"remaining_cents" => 11_000, "source_operation_id" => "op-cancel-rooms"}
             ] = data["lots"]

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_converted_to_credit_cents"] == 10_000
    end

    test "restores applied credit for the selected rooms", %{conn: conn} do
      open_group!(conn)

      {conn, _} =
        issue_credit(conn, %{"group_id" => "group-src", "operation_id" => "src"})

      json_post(
        conn,
        payment(%{"operation_id" => "pay-1", "amount_cents" => 9_000})
      )

      json_post(
        conn,
        apply_credit(%{
          "operation_id" => "apply-5000",
          "group_id" => "group-81",
          "occurred_on" => "2026-11-27",
          "amount_cents" => 5_000
        })
      )

      conn =
        json_post(
          conn,
          cancel_rooms(%{"room_ids" => ["room-b"], "occurred_on" => "2026-11-26"})
        )

      [result] = json_response(conn, 200)["results"]
      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      rooms_by_id = Map.new(data["rooms"], &{&1["room_id"], &1})
      assert rooms_by_id["room-a"]["credit_paid_cents"] == 0
      assert rooms_by_id["room-b"]["status"] == "cancelled"

      # The restored credit returned to its source lot.
      credit = json_response(get(conn, guest_credit_path("guest-22")), 200)["data"]
      assert credit["available_cents"] == 11_000
    end

    test "if no active rooms remain the group becomes cancelled", %{conn: conn} do
      open_group!(conn)

      conn = json_post(conn, cancel_rooms(%{"room_ids" => ["room-b"]}))

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["status"] == "active"

      conn = json_post(conn, cancel_rooms(%{"operation_id" => "op-2", "room_ids" => ["room-a"]}))
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["status"] == "cancelled"
      assert data["deposit_due_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0
    end

    test "rejects selections that are not distinct active rooms", %{conn: conn} do
      open_and_fund(conn)
      json_post(conn, cancel_rooms(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-26"}))

      for {operation_id, room_ids} <- [
            {"op-unknown", ["ghost"]},
            {"op-cancelled", ["room-a"]},
            {"op-dup", ["room-b", "room-b"]},
            {"op-empty", []},
            {"op-bad", ["room-b", "room-a", 7]}
          ] do
        [result] =
          json_response(
            json_post(
              conn,
              cancel_rooms(%{
                "operation_id" => operation_id,
                "room_ids" => room_ids,
                "occurred_on" => "2026-11-26"
              })
            ),
            200
          )["results"]

        assert result["code"] == "invalid_rooms"

        data = json_response(get(conn, groups_path("group-81")), 200)["data"]
        assert data["revision"] == 3
      end
    end

    test "a cancelled group rejects any selection with invalid_rooms", %{conn: conn} do
      open_group!(conn)
      json_post(conn, cancel())

      [result] =
        json_response(
          json_post(
            conn,
            cancel_rooms(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-26"})
          ),
          200
        )["results"]

      assert result["code"] == "invalid_rooms"
    end

    test "missing room_ids is invalid_operation", %{conn: conn} do
      open_group!(conn)

      op = Map.delete(cancel_rooms(), "room_ids")
      [result] = json_response(json_post(conn, op), 200)["results"]
      assert result["code"] == "invalid_operation"
    end

    test "a missing occurred_on is invalid_operation", %{conn: conn} do
      open_group!(conn)

      op = Map.delete(cancel_rooms(), "occurred_on")
      [result] = json_response(json_post(conn, op), 200)["results"]
      assert result["code"] == "invalid_operation"
    end

    test "new funding allocates only to the remaining active rooms", %{conn: conn} do
      open_and_fund(conn)
      json_post(conn, payment(%{"operation_id" => "pay-2", "amount_cents" => 3_000}))
      json_post(conn, cancel_rooms(%{"room_ids" => ["room-a"]}))

      conn =
        json_post(conn, payment(%{"operation_id" => "pay-3", "amount_cents" => 7_500}))

      assert [
               %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 5}
             ] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      rooms_by_id = Map.new(data["rooms"], &{&1["room_id"], &1})
      assert rooms_by_id["room-a"]["cash_paid_cents"] == 0
      assert rooms_by_id["room-b"]["cash_paid_cents"] == 10_500
      assert data["deposit_due_cents"] == 10_500
      assert data["deposit_paid_cents"] == 10_500
    end

    test "follows group existence, revision, and refund-method rules", %{conn: conn} do
      conn =
        json_post(conn, cancel_rooms(%{"group_id" => "ghost", "room_ids" => ["room-a"]}))

      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]

      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 5_000}))

      conn =
        json_post(
          conn,
          cancel_rooms(%{
            "operation_id" => "op-stale",
            "room_ids" => ["room-a"],
            "occurred_on" => "2026-11-26",
            "expected_revision" => 1
          })
        )

      assert [
               %{
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          cancel_rooms(%{
            "operation_id" => "op-bad-method",
            "room_ids" => ["room-a"],
            "occurred_on" => "2026-11-26",
            "refund_method" => "vouchers"
          })
        )

      assert [%{"code" => "invalid_operation"}] = json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          cancel_rooms(%{
            "operation_id" => "op-nonrefund-credit",
            "room_ids" => ["room-a"],
            "occurred_on" => "2026-12-01",
            "refund_method" => "hotel_credit"
          })
        )

      assert [%{"code" => "refund_method_not_available"}] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"status" => "active", "revision" => 2} = data
    end

    test "cancel_group settles only the remaining active rooms", %{conn: conn} do
      open_and_fund(conn)
      json_post(conn, payment(%{"operation_id" => "pay-2", "amount_cents" => 3_000}))

      conn =
        json_post(
          conn,
          cancel_rooms(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-26"})
        )

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      # room-b still holds 3_000; cancelling the group settles only that.
      conn =
        json_post(
          conn,
          cancel(%{
            "operation_id" => "op-cancel-rest",
            "occurred_on" => "2026-11-26"
          })
        )

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-cancel-rest",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 3_000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 5
                 }
               ]
             }

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["status"] == "cancelled"
    end

    test "is durably idempotent", %{conn: conn} do
      open_and_fund(conn)
      json_post(conn, payment(%{"operation_id" => "pay-2", "amount_cents" => 3_000}))

      op = cancel_rooms(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-26"})
      [original] = json_response(json_post(conn, op), 200)["results"]
      assert original["revision"] == 4

      assert [^original] = json_response(json_post(conn, op), 200)["results"]

      assert [%{"code" => "operation_id_conflict"}] =
               json_response(
                 json_post(conn, %{op | "room_ids" => ["room-b"]}),
                 200
               )["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["revision"] == 4
    end
  end

  defp issue_credit(conn, overrides) do
    group_id = Map.get(overrides, "group_id", "group-src")
    operation_id = Map.get(overrides, "operation_id", "group-src")

    conn =
      submit(conn, [
        open_group(%{
          "operation_id" => "open-#{operation_id}",
          "group_id" => group_id,
          "guest_id" => "guest-22"
        }),
        payment(%{
          "operation_id" => "pay-#{operation_id}",
          "group_id" => group_id,
          "amount_cents" => 10_000
        }),
        cancel(%{
          "operation_id" => "cancel-#{operation_id}",
          "group_id" => group_id,
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
      ])

    results = json_response(conn, 200)["results"]

    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             results

    {conn, Enum.at(results, 2)}
  end
end
