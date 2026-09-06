defmodule GroupStay.Acceptance.GroupDepositFlowTest do
  use GroupStayWeb.ConnCase

  @open_occurred_on "2026-10-03"
  @arrival_on "2026-12-10"
  @departure_on "2026-12-13"

  describe "POST /api/v1/partner-batches" do
    test "returns an empty results list for an empty batch", %{conn: conn} do
      conn = post_batch(conn, [])

      assert %{"results" => []} = json_response(conn, 200)
    end

    test "rejects a body without an operations array", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", Jason.encode!(%{"batches" => []}))

      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "rejects a body whose operations is not an array", %{conn: conn} do
      conn =
        post_batch(conn, %{"operation_id" => "op-1", "type" => "cancel_group"})

      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "applies the API example operation", %{conn: conn} do
      conn = post_batch(conn, [open_operation("group-81")])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "processes operations in order and continues after rejections", %{conn: conn} do
      operations = [
        open_operation("group-81"),
        open_operation("group-82") |> Map.put("operation_id", "op-open-82"),
        Map.put(open_operation("group-81"), "operation_id", "op-duplicate"),
        %{
          "operation_id" => "op-mystery",
          "type" => "teleport_group",
          "group_id" => "group-81",
          "occurred_on" => @open_occurred_on
        },
        cash_operation("op-pay", "group-82", 5_000)
      ]

      conn = post_batch(conn, operations)

      results = json_response(conn, 200)["results"]

      assert [
               %{"status" => "applied", "group_id" => "group-81"},
               %{"status" => "applied", "group_id" => "group-82"},
               %{"status" => "rejected", "code" => "group_already_exists"},
               %{"status" => "rejected", "code" => "invalid_operation"},
               %{"status" => "applied", "group_id" => "group-82"}
             ] = Enum.map(results, &Map.take(&1, ["status", "group_id", "code"]))

      # The rejected duplicate did not undo the earlier successful operation.
      assert %{"data" => %{"revision" => 1}} = get_group!("group-81")
    end

    test "echoes a missing operation_id as null on invalid_operation", %{conn: conn} do
      operation =
        open_operation("group-81")
        |> Map.delete("operation_id")

      conn = post_batch(conn, [operation])

      assert %{
               "results" => [
                 %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
               ]
             } = json_response(conn, 200)
    end
  end

  describe "opening a group" do
    test "stores booking fields, rooms in order, and totals", %{conn: conn} do
      operation =
        open_operation("group-order")
        |> Map.put("rooms", [
          %{"room_id" => "room-z", "nightly_rate_cents" => 12_345},
          %{"room_id" => "room-a", "nightly_rate_cents" => 10_000}
        ])

      post_batch(conn, [operation])

      assert %{
               "data" => %{
                 "group_id" => "group-order",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "revision" => 1,
                 "booked_on" => @open_occurred_on,
                 "arrival_on" => @arrival_on,
                 "departure_on" => @departure_on,
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-z", "nightly_rate_cents" => 12_345},
                   %{"room_id" => "room-a", "nightly_rate_cents" => 10_000}
                 ],
                 "lodging_total_cents" => 67_035,
                 "deposit_due_cents" => 13_407,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 13_407
               }
             } = get_group!("group-order")
    end

    test "an advance_purchase room requires its full lodging amount as deposit", %{conn: conn} do
      operation =
        open_operation("group-ap")
        |> Map.put("rate_plan", "advance_purchase")
        |> Map.put("rooms", [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])

      conn = post_batch(conn, [operation])

      assert %{"results" => [%{"status" => "applied", "deposit_due_cents" => 30_000}]} =
               json_response(conn, 200)
    end

    test "rounds each flexible room deposit separately before summing", %{conn: conn} do
      # Two rooms at one night each: per-room deposits are round(20.6) +
      # round(20.6) = 21 + 21 = 42; rounding once over the lump sum gives 41.
      operation =
        open_operation("group-rounding")
        |> Map.put("departure_on", "2026-12-11")
        |> Map.put("rooms", [
          %{"room_id" => "room-a", "nightly_rate_cents" => 103},
          %{"room_id" => "room-b", "nightly_rate_cents" => 103}
        ])

      conn = post_batch(conn, [operation])

      assert %{"results" => [%{"deposit_due_cents" => 42}]} = json_response(conn, 200)

      assert %{"data" => %{"lodging_total_cents" => 206}} = get_group!("group-rounding")
    end

    test "rejects a stay without at least one night and creates nothing", %{conn: conn} do
      zero_nights =
        open_operation("group-zero")
        |> Map.put("operation_id", "op-open-zero")
        |> Map.put("departure_on", @arrival_on)

      reversed =
        open_operation("group-reversed")
        |> Map.put("operation_id", "op-open-reversed")
        |> Map.put("departure_on", "2026-12-09")

      conn = post_batch(conn, [zero_nights, reversed])

      assert [
               %{"status" => "rejected", "code" => "invalid_stay"},
               %{"status" => "rejected", "code" => "invalid_stay"}
             ] = json_response(conn, 200)["results"]

      refute group_created?("group-zero")
      refute group_created?("group-reversed")
    end

    test "rejects rooms without at least one room or with duplicate identifiers", %{conn: conn} do
      no_rooms =
        open_operation("group-empty")
        |> Map.put("operation_id", "op-open-empty")
        |> Map.put("rooms", [])

      duplicates =
        open_operation("group-dupe")
        |> Map.put("operation_id", "op-open-dupe")
        |> Map.put("rooms", [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
        ])

      conn = post_batch(conn, [no_rooms, duplicates])

      assert [
               %{"status" => "rejected", "code" => "invalid_rooms"},
               %{"status" => "rejected", "code" => "invalid_rooms"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects an unknown rate plan and leaves no group behind", %{conn: conn} do
      operation =
        open_operation("group-standard")
        |> Map.put("rate_plan", "standard")

      conn = post_batch(conn, [operation])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rate_plan"}]} =
               json_response(conn, 200)

      refute group_created?("group-standard")
    end
  end

  describe "recording cash payments" do
    setup :opened_group

    test "applies cash to the outstanding deposit", %{conn: conn} do
      conn = post_batch(conn, [cash_operation("op-pay-1", "group-live", 10_000)])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "group_id" => "group-live",
                   "amount_cents" => 10_000,
                   "outstanding_deposit_cents" => 9_500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "allows paying up to exactly the outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          cash_operation("op-pay-1", "group-live", 10_000),
          cash_operation("op-pay-2", "group-live", 9_500),
          cash_operation("op-pay-3", "group-live", 1)
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "outstanding_deposit_cents" => 0},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects amounts that are not usable as payments", %{conn: conn} do
      conn =
        post_batch(conn, [
          cash_operation("op-zero", "group-live", 0),
          cash_operation("op-negative", "group-live", -5_000)
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_amount"},
               %{"status" => "rejected", "code" => "invalid_amount"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects payments for missing groups", %{conn: conn} do
      conn = post_batch(conn, [cash_operation("op-pay", "group-nope", 1_000)])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               json_response(conn, 200)
    end

    test "rejects payments after cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          cancel_operation("op-cancel", "group-live"),
          cash_operation("op-pay", "group-live", 1_000)
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "group_not_active"}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "rescheduling a group" do
    setup :opened_group

    test "shifts departure by the same number of days and keeps price", %{conn: conn} do
      conn = post_batch(conn, [reschedule_operation("op-move", "2026-11-01", "2026-12-20")])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "group_id" => "group-live",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-23",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "arrival_on" => "2026-12-20",
                 "departure_on" => "2026-12-23",
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "booked_on" => @open_occurred_on
               }
             } = get_group!("group-live")
    end

    test "rejects new arrivals that are not after the operation date", %{conn: conn} do
      conn =
        post_batch(conn, [
          reschedule_operation("op-same", "2026-12-10", "2026-12-10"),
          reschedule_operation("op-before", "2026-11-01", "2026-10-31"),
          reschedule_operation("op-garbage", "2026-11-01", "not-a-date")
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_stay"},
               %{"status" => "rejected", "code" => "invalid_stay"},
               %{"status" => "rejected", "code" => "invalid_stay"}
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"revision" => 1, "arrival_on" => @arrival_on}} =
               get_group!("group-live")
    end

    test "rejects moving a cancelled group", %{conn: conn} do
      conn =
        post_batch(conn, [
          cancel_operation("op-cancel", "group-live"),
          reschedule_operation("op-move", "2026-11-26", "2026-12-20")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "group_not_active"}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "cancelling a group" do
    test "refunds flexible reservations cancelled at least 14 days before arrival", %{conn: conn} do
      open_group(conn, "group-refund", "flexible")

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-refund", 8_000),
          cancel_operation("op-cancel", "group-refund")
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "group_id" => "group-refund",
                 "refunded_cents" => 8_000,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 8_000,
                 "cash_retained_cents" => 0
               }
             } = get_ledger!()
    end

    test "refunds when cancellation is exactly 14 days before arrival", %{conn: conn} do
      open_group(conn, "group-boundary", "flexible")

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-boundary", 5_000),
          cancel_operation("op-cancel", "group-boundary")
        ])

      # The cancellation date 2026-11-26 is exactly 14 calendar days before arrival.
      assert [%{"status" => "applied"}, %{"refunded_cents" => 5_000, "retained_cents" => 0}] =
               json_response(conn, 200)["results"]
    end

    test "retains cash for flexible reservations cancelled inside 14 days of arrival", %{
      conn: conn
    } do
      open_group(conn, "group-late", "flexible")

      late_cancel = %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-late"
      }

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-late", 7_000),
          late_cancel
        ])

      assert [%{"status" => "applied"}, %{"refunded_cents" => 0, "retained_cents" => 7_000}] =
               json_response(conn, 200)["results"]

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 7_000
               }
             } = get_ledger!()
    end

    test "always retains cash for advance-purchase reservations", %{conn: conn} do
      open_advance_purchase_group(conn, "group-ap")

      early_cancel = %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        # Far more than 14 days before arrival.
        "occurred_on" => "2026-10-05",
        "group_id" => "group-ap"
      }

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-ap", 30_000),
          early_cancel
        ])

      assert [%{"status" => "applied"}, %{"refunded_cents" => 0, "retained_cents" => 30_000}] =
               json_response(conn, 200)["results"]
    end

    test "cancels an unpaid group and drops the outstanding deposit", %{conn: conn} do
      open_group(conn, "group-unpaid", "flexible")

      conn = post_batch(conn, [cancel_operation("op-cancel", "group-unpaid")])

      assert [%{"refunded_cents" => 0, "retained_cents" => 0, "revision" => 2}] =
               json_response(conn, 200)["results"]

      # Group totals describe active rooms only; none remain active.
      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "lodging_total_cents" => 0,
                 "deposit_due_cents" => 0,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0,
                 "rooms" => [
                   %{"status" => "cancelled", "deposit_due_cents" => 9_000},
                   %{"status" => "cancelled", "deposit_due_cents" => 10_500}
                 ]
               }
             } = get_group!("group-unpaid")
    end

    test "a cancelled group rejects later payments, reschedules, and cancellations", %{conn: conn} do
      open_group(conn, "group-done", "flexible")

      follow_ups = [
        cancel_operation("op-cancel", "group-done"),
        cash_operation("op-pay", "group-done", 1_000),
        reschedule_operation("op-move", "2026-11-27", "2026-12-20", "group-done"),
        cancel_operation("op-cancel-again", "group-done")
      ]

      conn = post_batch(conn, follow_ups)

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "group_not_active"},
               %{"status" => "rejected", "code" => "group_not_active"},
               %{"status" => "rejected", "code" => "group_not_active"}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "revisions" do
    setup :opened_group

    test "increments exactly once per applied operation and never for rejections", %{conn: conn} do
      conn =
        post_batch(conn, [
          cash_operation("op-pay-ok", "group-live", 1_000),
          cash_operation("op-pay-rejected", "group-live", 999_999),
          reschedule_operation("op-move", "2026-11-01", "2026-12-20"),
          cancel_operation("op-cancel", "group-live")
        ])

      revisions = Enum.map(json_response(conn, 200)["results"], & &1["revision"])

      assert revisions == [2, nil, 3, 4]
    end

    test "applies when expected_revision matches the revision immediately before the operation",
         %{
           conn: conn
         } do
      payment =
        cash_operation("op-pay", "group-live", 1_000)
        |> Map.put("expected_revision", 1)

      conn = post_batch(conn, [payment])

      assert %{"results" => [%{"status" => "applied", "revision" => 2}]} =
               json_response(conn, 200)
    end

    test "sees changes made by earlier operations in the same batch", %{conn: conn} do
      pay_one =
        cash_operation("op-pay-1", "group-live", 1_000)
        |> Map.put("expected_revision", 1)

      pay_two =
        cash_operation("op-pay-2", "group-live", 1_000)
        |> Map.put("expected_revision", 2)

      conn = post_batch(conn, [pay_one, pay_two])

      assert [
               %{"status" => "applied", "revision" => 2},
               %{"status" => "applied", "revision" => 3}
             ] =
               json_response(conn, 200)["results"]
    end

    test "rejects stale revisions before other domain rules and leaves the group unchanged", %{
      conn: conn
    } do
      bump = cash_operation("op-bump", "group-live", 1_000)

      stale_and_exceeding =
        cash_operation("op-stale", "group-live", 999_999)
        |> Map.put("expected_revision", 1)

      conn = post_batch(conn, [bump, stale_and_exceeding])

      assert [
               %{"status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "op-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-live",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
               get_group!("group-live")
    end

    test "resolves existence before comparing revisions", %{conn: conn} do
      missing_with_expected =
        cash_operation("op-pay", "group-missing", 1_000)
        |> Map.put("expected_revision", 1)

      conn = post_batch(conn, [missing_with_expected])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               json_response(conn, 200)
    end

    test "omitting expected_revision preserves unconditional behavior", %{conn: conn} do
      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-live", 1_000),
          cash_operation("op-pay-2", "group-live", 1_000)
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}] =
               json_response(conn, 200)["results"]
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns 404 with a stable code for a missing group", %{conn: conn} do
      conn = get(conn, "/api/v1/groups/group-missing")

      assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero and tracks cash across several groups", %{conn: conn} do
      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = get_ledger!()

      open_group(conn, "group-one", "flexible")
      open_advance_purchase_group(conn, "group-two")

      post_batch(conn, [
        cash_operation("op-pay-1", "group-one", 4_000),
        cash_operation("op-pay-2", "group-two", 6_000)
      ])

      assert %{"data" => %{"cash_held_cents" => 10_000}} = get_ledger!()

      post_batch(conn, [cancel_operation("op-cancel-1", "group-one")])

      assert %{
               "data" => %{
                 "cash_held_cents" => 6_000,
                 "cash_refunded_cents" => 4_000,
                 "cash_retained_cents" => 0
               }
             } = get_ledger!()
    end

    test "unpaid deposits never appear in ledger totals", %{conn: conn} do
      open_group(conn, "group-unpaid", "flexible")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = get_ledger!()
    end
  end

  ## Helpers

  defp opened_group(context) do
    open_group(context.conn, "group-live", "flexible")
    :ok
  end

  defp open_group(conn, group_id, rate_plan) do
    conn
    |> post_batch([open_operation(group_id) |> Map.put("rate_plan", rate_plan)])
    |> json_response(200)
    |> assert_open_applied(group_id)
  end

  defp open_advance_purchase_group(conn, group_id) do
    operation =
      open_operation(group_id)
      |> Map.put("operation_id", "op-open-ap-#{group_id}")
      |> Map.put("rate_plan", "advance_purchase")
      |> Map.put("rooms", [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])

    conn
    |> post_batch([operation])
    |> json_response(200)
    |> assert_open_applied(group_id, 30_000)
  end

  defp assert_open_applied(%{"results" => [result]}, group_id, due \\ 19_500) do
    assert %{
             "status" => "applied",
             "group_id" => ^group_id,
             "deposit_due_cents" => ^due,
             "revision" => 1
           } = result
  end

  defp open_operation(group_id) do
    %{
      "operation_id" => "op-1001",
      "type" => "open_group",
      "occurred_on" => @open_occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => @arrival_on,
      "departure_on" => @departure_on,
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end

  defp cash_operation(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reschedule_operation(operation_id, occurred_on, new_arrival_on, group_id \\ "group-live") do
    %{
      "operation_id" => operation_id,
      "type" => "reschedule_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "new_arrival_on" => new_arrival_on
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on \\ "2026-11-26") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp post_batch(_conn, operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp get_group!(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  defp get_ledger! do
    build_conn()
    |> get("/api/v1/ledger")
    |> json_response(200)
  end

  defp group_created?(group_id) do
    response = build_conn() |> get("/api/v1/groups/#{group_id}")
    response.status == 200
  end
end
