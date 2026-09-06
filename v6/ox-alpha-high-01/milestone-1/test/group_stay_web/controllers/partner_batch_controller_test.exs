defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import Phoenix.ConnTest

  @moduletag :capture_log

  defp run_batch(conn, operations) do
    conn |> submit_batch(operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp group_json(conn, group_id) do
    %{"data" => group} = conn |> get_group(group_id) |> json_response(200)
    group
  end

  defp open_group(conn, overrides \\ %{}) do
    assert [%{"status" => "applied"} = result] = run_batch(conn, [open_operation(overrides)])
    result
  end

  describe "POST /api/v1/partner-batches with an invalid batch" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = submit_raw(conn, Jason.encode!(%{}))

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects a non-list operations value", %{conn: conn} do
      body = Jason.encode!(%{"operations" => "nope"})
      conn = submit_raw(conn, body)

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end
  end

  describe "open_group" do
    test "applies the API example and reports deposit due and revision", %{conn: conn} do
      assert run_batch(conn, [open_operation()]) == [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
    end

    test "rounds each flexible room deposit separately", %{conn: conn} do
      results =
        run_batch(conn, [
          open_operation(
            operation_id: "op-round",
            group_id: "group-round",
            arrival_on: "2026-12-10",
            departure_on: "2026-12-11",
            rooms: [
              %{"room_id" => "room-a", "nightly_rate_cents" => 1237},
              %{"room_id" => "room-b", "nightly_rate_cents" => 1238},
              %{"room_id" => "room-c", "nightly_rate_cents" => 1245}
            ]
          )
        ])

      # Lodging of 1237 -> 20% is 247.4 -> 247; 1238 -> 247.6 -> 248; 1245 -> 249.
      assert [%{"deposit_due_cents" => 744}] = results
    end

    test "an advance_purchase room deposits its full lodging amount", %{conn: conn} do
      result =
        open_group(conn,
          operation_id: "op-ap",
          group_id: "group-ap",
          rate_plan: "advance_purchase"
        )

      # 3 nights * (15000 + 17500)
      assert result["deposit_due_cents"] == 97_500
    end

    test "records the operation date as booked_on and keeps rooms in order", %{conn: conn} do
      open_group(conn, rooms: open_operation()["rooms"] |> Enum.reverse())

      group = group_json(conn, "group-81")

      assert group["booked_on"] == "2026-10-03"
      assert Enum.map(group["rooms"], & &1["room_id"]) == ["room-b", "room-a"]
    end

    test "rejects a duplicate group identifier without touching the original", %{conn: conn} do
      open_group(conn)

      results =
        run_batch(conn, [
          open_operation(
            operation_id: "op-dup",
            guest_id: "guest-other",
            arrival_on: "2027-01-01",
            departure_on: "2027-01-05"
          )
        ])

      assert results == [
               %{
                 "operation_id" => "op-dup",
                 "status" => "rejected",
                 "code" => "group_already_exists",
                 "group_id" => "group-81"
               }
             ]

      group = group_json(conn, "group-81")
      assert group["revision"] == 1
      assert group["arrival_on"] == "2026-12-10"
    end

    test "rejects stays without at least one night", %{conn: conn} do
      for {arrival, departure} <- [{"2026-12-10", "2026-12-10"}, {"2026-12-13", "2026-12-10"}] do
        results =
          run_batch(conn, [
            open_operation(
              operation_id: "op-stay",
              group_id: "group-stay",
              arrival_on: arrival,
              departure_on: departure
            )
          ])

        assert [%{"status" => "rejected", "code" => "invalid_stay", "group_id" => "group-stay"}] =
                 results
      end

      refute_group(conn, "group-stay")
    end

    test "rejects unusable stay dates", %{conn: conn} do
      for bad <- ["not-a-date", "2026-13-99", "", 42] do
        results =
          run_batch(conn, [
            open_operation(
              operation_id: "op-stay",
              group_id: "group-stay",
              arrival_on: bad
            )
          ])

        assert [%{"status" => "rejected", "code" => "invalid_stay"}] = results
      end

      refute_group(conn, "group-stay")
    end

    test "rejects empty or duplicated rooms", %{conn: conn} do
      results =
        run_batch(conn, [
          open_operation(operation_id: "op-r1", group_id: "g-empty", rooms: []),
          open_operation(
            operation_id: "op-r2",
            group_id: "g-dup",
            rooms: [
              %{"room_id" => "room-a", "nightly_rate_cents" => 1000},
              %{"room_id" => "room-a", "nightly_rate_cents" => 2000}
            ]
          )
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_rooms", "group_id" => "g-empty"},
               %{"status" => "rejected", "code" => "invalid_rooms", "group_id" => "g-dup"}
             ] = results

      refute_group(conn, "g-empty")
      refute_group(conn, "g-dup")
    end

    test "rejects rooms with unusable nightly rates or identifiers", %{conn: conn} do
      bad_rooms = [
        [%{"room_id" => "room-a", "nightly_rate_cents" => 0}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => -100}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => 15.5}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}],
        [%{"room_id" => "", "nightly_rate_cents" => 15000}],
        [%{"room_id" => 7, "nightly_rate_cents" => 15000}],
        ["room-a"]
      ]

      results =
        run_batch(
          conn,
          Enum.with_index(bad_rooms, fn rooms, index ->
            open_operation(
              operation_id: "op-bad-room-#{index}",
              group_id: "g-bad-room-#{index}",
              rooms: rooms
            )
          end)
        )

      assert Enum.all?(results, fn result ->
               result["status"] == "rejected" and result["code"] == "invalid_rooms"
             end)

      refute_group(conn, "g-bad-room-0")
    end

    test "rejects unknown rate plans", %{conn: conn} do
      results =
        run_batch(conn, [
          open_operation(operation_id: "op-rate", group_id: "g-rate", rate_plan: "super-flexible")
        ])

      assert [%{"status" => "rejected", "code" => "invalid_rate_plan", "group_id" => "g-rate"}] =
               results

      refute_group(conn, "g-rate")
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      open_group(conn)

      results =
        run_batch(conn, [
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 5000
          }
        ])

      assert results == [
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]

      group = group_json(conn, "group-81")
      assert group["deposit_paid_cents"] == 5000
      assert group["outstanding_deposit_cents"] == 14_500
    end

    test "rejects payments exceeding the outstanding deposit", %{conn: conn} do
      open_group(conn)

      results =
        run_batch(conn, [
          payment_operation("op-over", 19_501),
          payment_operation("op-full", 19_500),
          payment_operation("op-after-full", 1)
        ])

      assert [
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
               %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 2},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"}
             ] = results

      group = group_json(conn, "group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 19_500
      assert group["outstanding_deposit_cents"] == 0
    end

    test "rejects amounts that are not usable payments", %{conn: conn} do
      open_group(conn)

      amounts = [0, -5, "5000", 50.5]

      results =
        run_batch(
          conn,
          Enum.with_index(amounts, fn amount, index ->
            payment_operation("op-amount-#{index}", amount)
          end)
        )

      assert Enum.all?(results, fn result ->
               result["status"] == "rejected" and result["code"] == "invalid_amount"
             end)

      group = group_json(conn, "group-81")
      assert group["deposit_paid_cents"] == 0
      assert group["revision"] == 1
    end

    test "treats an explicit null amount as missing data", %{conn: conn} do
      open_group(conn)

      results = run_batch(conn, [payment_operation("op-null", nil)])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] = results
    end

    test "rejects payments to missing groups", %{conn: conn} do
      results = run_batch(conn, [payment("op-missing", "ghost-group", 500)])

      assert results == [
               %{
                 "operation_id" => "op-missing",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "ghost-group"
               }
             ]
    end

    test "rejects payments after cancellation", %{conn: conn} do
      open_group(conn)
      cancel(conn, "op-cancel", "2026-11-01")

      results = run_batch(conn, [payment_operation("op-late-pay", 100)])

      assert [%{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-81"}] =
               results
    end
  end

  describe "reschedule_group" do
    test "shifts both stay dates by the same number of days", %{conn: conn} do
      open_group(conn)

      results =
        run_batch(conn, [
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-24"
          }
        ])

      assert results == [
               %{
                 "operation_id" => "op-move",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-24",
                 "new_departure_on" => "2026-12-27",
                 "revision" => 2
               }
             ]

      group = group_json(conn, "group-81")
      assert group["arrival_on"] == "2026-12-24"
      assert group["departure_on"] == "2026-12-27"
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
    end

    test "rejects arrivals on or before the operation date", %{conn: conn} do
      open_group(conn)

      results =
        run_batch(conn, [
          move_operation("op-too-early", "2026-10-02"),
          move_operation("op-same-day", "2026-10-03")
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_stay"},
               %{"status" => "rejected", "code" => "invalid_stay"}
             ] = results

      group = group_json(conn, "group-81")
      assert group["revision"] == 1
      assert group["arrival_on"] == "2026-12-10"
    end

    test "rejects unusable new arrival dates", %{conn: conn} do
      open_group(conn)

      results = run_batch(conn, [move_operation("op-garbage", "31/12/2026")])

      assert [%{"status" => "rejected", "code" => "invalid_stay"}] = results
    end

    test "resolves group existence first and rejects inactive groups", %{conn: conn} do
      open_group(conn)
      cancel(conn, "op-cancel", "2026-11-01")

      results =
        run_batch(conn, [
          move("op-ghost", "ghost-group", "2026-12-24"),
          move("op-cancelled", "group-81", "2026-12-24")
        ])

      assert [
               %{"code" => "group_not_found", "group_id" => "ghost-group"},
               %{"code" => "group_not_active", "group_id" => "group-81"}
             ] = results
    end
  end

  describe "cancel_group" do
    test "refunds flexible reservations cancelled at least 14 days before arrival", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 8000)])

      result = cancel(conn, "op-cancel", "2026-11-26")

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 8000,
               "retained_cents" => 0,
               "revision" => 3
             }

      group = group_json(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
    end

    test "retains cash from flexible reservations cancelled inside 14 days", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 8000)])

      result = cancel(conn, "op-cancel", "2026-11-27")

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 8000
      assert result["revision"] == 3
    end

    test "always retains cash for advance_purchase reservations", %{conn: conn} do
      open_group(conn, group_id: "group-ap", rate_plan: "advance_purchase")
      run_batch(conn, [payment("op-pay-ap", "group-ap", 97_500)])

      result = cancel(conn, "op-cancel-ap", "2026-10-04", "group-ap")

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 97_500
    end

    test "a cancelled group rejects later operations with group_not_active", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 1000)])
      cancel(conn, "op-cancel", "2026-11-01")

      results =
        run_batch(conn, [
          payment_operation("op-repay", 1000),
          move_operation("op-remove", "2026-12-24"),
          %{
            "operation_id" => "op-recancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-02",
            "group_id" => "group-81"
          }
        ])

      assert Enum.all?(results, fn result ->
               result["status"] == "rejected" and result["code"] == "group_not_active"
             end)

      group = group_json(conn, "group-81")
      assert group["revision"] == 3
      assert group["deposit_paid_cents"] == 1000
    end

    test "rejects cancellation of a missing group", %{conn: conn} do
      results =
        run_batch(conn, [
          %{
            "operation_id" => "op-ghost-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "ghost-group"
          }
        ])

      assert [%{"status" => "rejected", "code" => "group_not_found", "group_id" => "ghost-group"}] =
               results
    end
  end

  describe "revisions and expected_revision" do
    test "every applied operation increments the revision exactly once", %{conn: conn} do
      open_group(conn)

      revisions =
        run_batch(conn, [
          payment_operation("op-1", 100),
          move_operation("op-2", "2026-12-11"),
          %{
            "operation_id" => "op-3",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81"
          }
        ])
        |> Enum.map(& &1["revision"])

      assert revisions == [2, 3, 4]
    end

    test "matching expected_revision applies against the pre-operation revision", %{conn: conn} do
      open_group(conn)

      results =
        run_batch(conn, [
          Map.put(payment_operation("op-first", 100), "expected_revision", 1),
          Map.put(payment_operation("op-second", 100), "expected_revision", 1),
          Map.put(payment_operation("op-third", 100), "expected_revision", 2)
        ])

      assert [%{"status" => "applied", "revision" => 2}, second, third] = results

      assert second["status"] == "rejected"
      assert second["code"] == "stale_revision"
      assert second["expected_revision"] == 1
      assert second["actual_revision"] == 2

      assert third["status"] == "applied"
      assert third["revision"] == 3
    end

    test "a stale revision rejection leaves the group and ledger unchanged", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 2500)])
      ledger_before = ledger_json(conn)

      results =
        run_batch(conn, [
          Map.put(payment_operation("op-stale", 100), "expected_revision", 1)
        ])

      assert results == [
               %{
                 "operation_id" => "op-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]

      group = group_json(conn, "group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 2500
      assert ledger_json(conn) == ledger_before
    end

    test "group existence resolves before the revision comparison", %{conn: conn} do
      results =
        run_batch(conn, [
          Map.put(payment_operation("op-ghost", 100), "expected_revision", 1)
        ])

      assert [%{"status" => "rejected", "code" => "group_not_found"}] = results
    end

    test "omitting expected_revision keeps unconditional behavior", %{conn: conn} do
      open_group(conn)

      results = run_batch(conn, [payment_operation("op-no-expectation", 100)])

      assert [%{"status" => "applied", "revision" => 2}] = results
    end
  end

  describe "batch processing" do
    test "operations observe earlier operations in the same batch", %{conn: conn} do
      results =
        run_batch(conn, [
          open_operation(),
          payment_operation("op-pay", 1950)
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "outstanding_deposit_cents" => 17_550, "revision" => 2}
             ] = results
    end

    test "a rejected operation does not stop later operations or undo earlier ones", %{conn: conn} do
      results =
        run_batch(conn, [
          open_operation(),
          payment_operation("op-too-much", 99_999),
          open_operation(operation_id: "op-dupe", group_id: "group-81"),
          payment_operation("op-fine", 100)
        ])

      statuses = Enum.map(results, fn r -> {r["status"], r["code"]} end)

      assert statuses == [
               {"applied", nil},
               {"rejected", "payment_exceeds_outstanding"},
               {"rejected", "group_already_exists"},
               {"applied", nil}
             ]

      group = group_json(conn, "group-81")
      assert group["deposit_paid_cents"] == 100
      assert group["revision"] == 2
    end

    test "unknown types and operations missing identifying data are invalid operations", %{
      conn: conn
    } do
      results =
        run_batch(conn, [
          %{"operation_id" => "op-unknown", "type" => "teleport_group", "group_id" => "group-x"},
          %{"operation_id" => "op-typeless", "group_id" => "group-x"},
          %{"type" => "record_cash_payment", "operation_id" => "op-no-group"},
          Map.delete(open_operation(), "rooms"),
          Map.delete(open_operation(), "group_id"),
          Map.merge(open_operation(), %{"occurred_on" => "yesterday"}),
          "not-even-a-map"
        ])

      codes = Enum.map(results, &%{&1["status"] => &1["code"]})

      assert codes == [
               %{"rejected" => "invalid_operation"},
               %{"rejected" => "invalid_operation"},
               %{"rejected" => "invalid_operation"},
               %{"rejected" => "invalid_operation"},
               %{"rejected" => "invalid_operation"},
               %{"rejected" => "invalid_operation"},
               %{"rejected" => "invalid_operation"}
             ]

      refute_group(conn, "group-81")
    end

    test "blank identifiers are invalid operations", %{conn: conn} do
      results = run_batch(conn, [open_operation(group_id: "")])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] = results
    end
  end

  defp payment_operation(operation_id, amount_cents),
    do: payment(operation_id, "group-81", amount_cents)

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp move_operation(operation_id, new_arrival_on),
    do: move(operation_id, "group-81", new_arrival_on)

  defp move(operation_id, group_id, new_arrival_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "new_arrival_on" => new_arrival_on
    }
  end

  defp cancel(conn, operation_id, occurred_on, group_id \\ "group-81") do
    operation = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    assert [%{"status" => "applied"} = result] = run_batch(conn, [operation])
    result
  end

  defp refute_group(conn, group_id) do
    conn = get_group(conn, group_id)
    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  defp ledger_json(conn) do
    %{"data" => data} = conn |> get_ledger() |> json_response(200)
    data
  end
end
