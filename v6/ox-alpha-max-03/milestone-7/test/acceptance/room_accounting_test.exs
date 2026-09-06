defmodule GroupStay.Acceptance.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  @open_occurred_on "2026-10-03"
  @arrival_on "2026-12-10"
  @departure_on "2026-12-13"
  @refundable_until_flex14 "2026-11-26"

  # Rooms a and b: lodgings 45_000 and 52_500; deposits 9_000 and 10_500.
  defp open_operation(group_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @open_occurred_on),
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => Keyword.get(opts, :arrival_on, @arrival_on),
      "departure_on" => Keyword.get(opts, :departure_on, @departure_on),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" =>
        Keyword.get(opts, :rooms, [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ])
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

  defp apply_credit_operation(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_rooms_operation(
         operation_id,
         group_id,
         room_ids,
         occurred_on \\ @refundable_until_flex14
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "room_ids" => room_ids
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on \\ @refundable_until_flex14) do
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
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_group!(group_id) do
    build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200)
  end

  defp get_ledger! do
    build_conn() |> get("/api/v1/ledger") |> json_response(200)
  end

  # Gives guest-22 an 8_800 credit lot through a refundable hotel-credit
  # cancellation of a helper group.
  defp give_guest_credit(_conn) do
    results =
      post_batch(build_conn(), [
        open_operation("group-credit-source"),
        cash_operation("op-pay-source", "group-credit-source", 8_000),
        cancel_operation("op-cancel-source", "group-credit-source")
        |> Map.put("refund_method", "hotel_credit")
      ])

    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             results
  end

  describe "room-level accounting on group reads" do
    test "rooms expose lodging, deposit due, status, and paid amounts", %{conn: conn} do
      give_guest_credit(conn)

      post_batch(
        conn,
        [
          open_operation("group-live"),
          cash_operation("op-pay-1", "group-live", 12_000),
          apply_credit_operation("op-credit-1", "group-live", 4_000)
        ]
      )

      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "cash_paid_cents" => 12_000,
                 "credit_paid_cents" => 4_000,
                 "deposit_paid_cents" => 16_000,
                 "outstanding_deposit_cents" => 3_500,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "nightly_rate_cents" => 15_000,
                     "lodging_amount_cents" => 45_000,
                     "status" => "active",
                     "deposit_due_cents" => 9_000,
                     "cash_paid_cents" => 9_000,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "nightly_rate_cents" => 17_500,
                     "lodging_amount_cents" => 52_500,
                     "status" => "active",
                     "deposit_due_cents" => 10_500,
                     "cash_paid_cents" => 3_000,
                     "credit_paid_cents" => 4_000
                   }
                 ]
               }
             } = get_group!("group-live")
    end

    test "cash fills one room's deposit before moving to the next", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-fill"),
        cash_operation("op-pay-1", "group-fill", 9_500),
        cash_operation("op-pay-2", "group-fill", 100)
      ])

      assert %{"data" => %{"rooms" => [first, second]}} = get_group!("group-fill")

      assert %{"room_id" => "room-a", "cash_paid_cents" => 9_000} = first
      assert %{"room_id" => "room-b", "cash_paid_cents" => 600} = second
    end

    test "reading a group never changes any state", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-read"),
        cash_operation("op-pay", "group-read", 2_000)
      ])

      before = get_group!("group-read")
      get_group!("group-read")
      after_read = get_group!("group-read")

      assert before == after_read
    end
  end

  describe "cancel_rooms settlement" do
    setup do
      results =
        post_batch(
          build_conn(),
          [
            open_operation("group-live"),
            cash_operation("op-pay-1", "group-live", 12_000)
          ]
        )

      assert [%{"status" => "applied"}, %{"status" => "applied"}] = results
      :ok
    end

    test "settles only the selected rooms' allocated cash as a refund", %{conn: conn} do
      results =
        post_batch(conn, [cancel_rooms_operation("op-cancel-b", "group-live", ["room-b"])])

      assert [
               %{
                 "operation_id" => "op-cancel-b",
                 "status" => "applied",
                 "group_id" => "group-live",
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 3_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = results

      # The remaining active rooms describe the totals now.
      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 45_000,
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 9_000,
                 "outstanding_deposit_cents" => 0,
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 9_000},
                   %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
                 ]
               }
             } = get_group!("group-live")

      assert %{"data" => %{"cash_held_cents" => 9_000, "cash_refunded_cents" => 3_000}} =
               get_ledger!()
    end

    test "returns cancelled_room_ids in original room order regardless of caller order", %{
      conn: conn
    } do
      results =
        post_batch(
          conn,
          [cancel_rooms_operation("op-cancel-both", "group-live", ["room-b", "room-a"])]
        )

      assert [%{"cancelled_room_ids" => ["room-a", "room-b"], "refunded_cents" => 12_000}] =
               results
    end

    test "unpaid deposit for selected rooms ceases to be due", %{conn: conn} do
      post_batch(conn, [open_operation("group-unpaid")])

      post_batch(conn, [cancel_rooms_operation("op-cancel-a", "group-unpaid", ["room-a"])])

      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 52_500,
                 "deposit_due_cents" => 10_500,
                 "outstanding_deposit_cents" => 10_500,
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "cancelled"},
                   %{"room_id" => "room-b", "status" => "active"}
                 ]
               }
             } = get_group!("group-unpaid")
    end

    test "computes the hotel-credit bonus once on the combined cash", %{conn: conn} do
      # Two rooms at 26/night for one night: each deposit is round(5.2) = 6.
      # Combined cash 12 earns half_up(1.2) = 1 bonus once: issued 13. Bonus per
      # room would have rounded up twice and issued 14.
      post_batch(conn, [
        open_operation("group-combined",
          rooms: [
            %{"room_id" => "room-a", "nightly_rate_cents" => 26},
            %{"room_id" => "room-b", "nightly_rate_cents" => 26}
          ]
        ),
        cash_operation("op-pay", "group-combined", 12)
      ])

      results =
        post_batch(conn, [
          cancel_rooms_operation("op-cancel-both", "group-combined", ["room-a", "room-b"])
          |> Map.put("refund_method", "hotel_credit")
        ])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 13
               }
             ] = results

      assert %{"data" => %{"available_cents" => 13}} =
               build_conn() |> get("/api/v1/guests/guest-22/credit") |> json_response(200)

      assert %{"data" => %{"cash_converted_to_credit_cents" => 12}} = get_ledger!()
    end

    test "retains selected rooms' cash when cancelling inside the window", %{conn: conn} do
      results =
        post_batch(conn, [
          cancel_rooms_operation("op-late", "group-live", ["room-a"], "2026-12-01")
        ])

      assert [
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-a"],
                 "refunded_cents" => 0,
                 "retained_cents" => 9_000
               }
             ] = results

      assert %{"data" => %{"cash_retained_cents" => 9_000, "cash_held_cents" => 3_000}} =
               get_ledger!()
    end

    test "rejects anything but distinct active rooms with invalid_rooms", %{conn: conn} do
      results =
        post_batch(conn, [
          cancel_rooms_operation("op-dupes", "group-live", ["room-a", "room-a"]),
          cancel_rooms_operation("op-unknown", "group-live", ["room-z"]),
          cancel_rooms_operation("op-empty", "group-live", []),
          cancel_rooms_operation("op-mixed", "group-live", ["room-a", "room-z"]),
          cancel_rooms_operation("op-not-list", "group-live", "room-a")
        ])

      codes = Enum.map(results, & &1["code"])

      assert codes == [
               "invalid_rooms",
               "invalid_rooms",
               "invalid_rooms",
               "invalid_rooms",
               "invalid_operation"
             ]

      # Nothing moved and no revision advanced.
      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 12_000}} =
               get_group!("group-live")

      assert %{"data" => %{"cash_held_cents" => 12_000}} = get_ledger!()
    end

    test "cancelling every active room cancels the group", %{conn: conn} do
      results =
        post_batch(conn, [cancel_rooms_operation("op-cancel-a", "group-live", ["room-a"])])

      assert [%{"status" => "applied"}] = results

      results =
        post_batch(conn, [cancel_rooms_operation("op-cancel-b", "group-live", ["room-b"])])

      assert [%{"status" => "applied", "cancelled_room_ids" => ["room-b"], "revision" => 4}] =
               results

      assert %{"data" => %{"status" => "cancelled"}} = get_group!("group-live")

      follow_ups =
        post_batch(conn, [
          cash_operation("op-pay", "group-live", 1_000),
          cancel_rooms_operation("op-again", "group-live", ["room-a"]),
          cancel_operation("op-full", "group-live")
        ])

      assert [
               %{"code" => "group_not_active"},
               %{"code" => "group_not_active"},
               %{"code" => "group_not_active"}
             ] = follow_ups
    end

    test "a later payment funds the remaining capacity of still-active rooms", %{conn: conn} do
      post_batch(conn, [cancel_rooms_operation("op-cancel-a", "group-live", ["room-a"])])

      # room-b still holds 3_000 of its 10_500 deposit, so 7_500 fits.
      results = post_batch(conn, [cash_operation("op-pay-2", "group-live", 7_000)])

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 500}] = results

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
                   %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 10_000}
                 ]
               }
             } = get_group!("group-live")
    end

    test "cancel_group settles only the remaining active rooms", %{conn: conn} do
      post_batch(conn, [cancel_rooms_operation("op-cancel-a", "group-live", ["room-a"])])

      results = post_batch(conn, [cancel_operation("op-cancel-rest", "group-live")])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 3_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] = results

      assert %{"data" => %{"status" => "cancelled"}} = get_group!("group-live")

      assert %{"data" => %{"cash_held_cents" => 0, "cash_refunded_cents" => 12_000}} =
               get_ledger!()
    end

    test "follows the revision contract with derived stale details", %{conn: conn} do
      stale =
        cancel_rooms_operation("op-stale", "group-live", ["room-a"])
        |> Map.put("expected_revision", 1)

      results = post_batch(conn, [stale])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-live",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = results

      assert %{"data" => %{"revision" => 2, "status" => "active"}} = get_group!("group-live")
    end

    test "is durably idempotent like every other operation", %{conn: conn} do
      operation = cancel_rooms_operation("op-once", "group-live", ["room-b"])

      first = post_batch(conn, [operation])
      retry = post_batch(conn, [operation])

      expected = %{
        "operation_id" => "op-once",
        "status" => "applied",
        "group_id" => "group-live",
        "cancelled_room_ids" => ["room-b"],
        "refunded_cents" => 3_000,
        "retained_cents" => 0,
        "credit_issued_cents" => 0,
        "revision" => 3
      }

      assert [^expected] = first
      # The exact stored result replays without touching state again.
      assert [^expected] = retry

      assert %{"data" => %{"revision" => 3}} = get_group!("group-live")
      assert %{"data" => %{"cash_refunded_cents" => 3_000}} = get_ledger!()

      conflicting =
        cancel_rooms_operation("op-once", "group-live", ["room-a"])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               post_batch(conn, [conflicting])
    end

    test "hotel credit cannot bypass a non-refundable partial cancellation", %{conn: conn} do
      results =
        post_batch(conn, [
          cancel_rooms_operation("op-late", "group-live", ["room-a"], "2026-12-01")
          |> Map.put("refund_method", "hotel_credit")
        ])

      assert [%{"status" => "rejected", "code" => "refund_method_not_available"}] = results

      assert %{"data" => %{"status" => "active", "revision" => 2, "cash_paid_cents" => 12_000}} =
               get_group!("group-live")
    end

    test "restores applied hotel credit from cancelled rooms to its lot", %{conn: conn} do
      give_guest_credit(conn)

      post_batch(conn, [apply_credit_operation("op-apply", "group-live", 5_000)])

      # The 12_000 cash fills room-a (9_000) and room-b (3_000); the credit
      # then continues into room-b's remaining capacity.
      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "credit_paid_cents" => 0},
                   %{"room_id" => "room-b", "credit_paid_cents" => 5_000}
                 ]
               }
             } = get_group!("group-live")

      results =
        post_batch(conn, [cancel_rooms_operation("op-cancel-b", "group-live", ["room-b"])])

      # Only room-b's cash refunds; its credit returns to the lot untouched.
      assert [%{"status" => "applied", "refunded_cents" => 3_000}] = results

      assert %{"data" => %{"available_cents" => 8_800, "lots" => [lot]}} =
               build_conn() |> get("/api/v1/guests/guest-22/credit") |> json_response(200)

      assert %{"remaining_cents" => 8_800} = lot

      assert %{"data" => %{"credit_liability_cents" => 8_800}} = get_ledger!()

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 9_000},
                   %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
                 ],
                 "cash_paid_cents" => 9_000,
                 "outstanding_deposit_cents" => 0
               }
             } = get_group!("group-live")
    end
  end
end
