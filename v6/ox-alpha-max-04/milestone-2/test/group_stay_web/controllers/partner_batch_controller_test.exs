defmodule GroupStayWeb.Controllers.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: true

  @arrival "2026-12-10"
  @departure "2026-12-13"
  @occurred_on "2026-10-03"

  describe "batch envelope" do
    test "returns one result per operation in array order", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{"operation_id" => "op-1", "group_id" => "group-a"}),
          open_group_operation(%{"operation_id" => "op-2", "group_id" => "group-b"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert [%{"operation_id" => "op-1"}, %{"operation_id" => "op-2"}] = results
      assert Enum.all?(results, &(&1["status"] == "applied"))
    end

    test "an empty operations array is a valid empty batch", %{conn: conn} do
      conn = post_operations(conn, [])
      assert %{"results" => []} = json_response(conn, 200)
    end

    test "a body without an operations array is rejected with 422", %{conn: conn} do
      conn = post_batch_body(conn, Jason.encode!(%{"batches" => []}))
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "operations that is not an array is rejected with 422", %{conn: conn} do
      conn = post_batch_body(conn, Jason.encode!(%{"operations" => "open everything"}))
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "a body that is not a JSON object is rejected with 422", %{conn: conn} do
      conn = post_batch_body(conn, Jason.encode!(["open_group"]))
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "an empty JSON body is rejected with 422", %{conn: conn} do
      conn = post_batch_body(conn, "{}")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "a rejected operation does not stop later operations nor undo earlier ones", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(%{"operation_id" => "op-1", "group_id" => "group-81"}),
          open_group_operation(%{"operation_id" => "op-2", "group_id" => "group-81"}),
          record_payment_operation(%{
            "operation_id" => "op-3",
            "group_id" => "group-81",
            "amount_cents" => 10_000
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)

      assert [
               %{"status" => "applied", "group_id" => "group-81", "revision" => 1},
               %{"status" => "rejected", "code" => "group_already_exists"},
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "outstanding_deposit_cents" => 9_500
               }
             ] = results

      assert %{"revision" => 2, "deposit_paid_cents" => 10_000} = fetch_group!(conn, "group-81")
    end
  end

  describe "open_group" do
    test "applies the API example and creates revision 1", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation()])

      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-1001",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }

      group = fetch_group!(conn, "group-81")

      assert group ==
               %{
                 "group_id" => "group-81",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "revision" => 1,
                 "booked_on" => @occurred_on,
                 "arrival_on" => @arrival,
                 "departure_on" => @departure,
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ],
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500,
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26"
               }
    end

    test "keeps rooms in their original order regardless of rate or name", %{conn: conn} do
      rooms = [
        %{"room_id" => "zebra", "nightly_rate_cents" => 20_000},
        %{"room_id" => "alpha", "nightly_rate_cents" => 10_000},
        %{"room_id" => "middle", "nightly_rate_cents" => 15_000}
      ]

      conn =
        post_operations(conn, [
          open_group_operation(%{"group_id" => "group-order", "rooms" => rooms})
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)
      assert %{"rooms" => rendered} = fetch_group!(conn, "group-order")
      assert Enum.map(rendered, & &1["room_id"]) == ["zebra", "alpha", "middle"]
    end

    test "an advance_purchase room deposits its full lodging amount", %{conn: conn} do
      op =
        open_group_operation(%{
          "group_id" => "group-ap",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
        })

      conn = post_operations(conn, [op])

      assert %{"results" => [%{"deposit_due_cents" => 45_000, "revision" => 1}]} =
               json_response(conn, 200)
    end

    test "rounds each flexible room deposit separately, then sums", %{conn: conn} do
      # Two rooms, 3 nights at 10001: lodging 30003 each. 20% is 6000.6, so
      # each room rounds to 6001 and the group deposit is 12002. Summing
      # before rounding would give 12001 instead.
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10_001},
        %{"room_id" => "room-b", "nightly_rate_cents" => 10_001}
      ]

      conn =
        post_operations(conn, [
          open_group_operation(%{"group_id" => "group-round", "rooms" => rooms})
        ])

      assert %{"results" => [%{"deposit_due_cents" => 12_002}]} = json_response(conn, 200)

      assert %{"lodging_total_cents" => 60_006, "deposit_due_cents" => 12_002} =
               fetch_group!(conn, "group-round")
    end

    test "rounds fractional deposit cents to the nearest cent", %{conn: conn} do
      # 3 nights at 3333 = 9999 lodging; 20% is 1999.8, which rounds to 2000.
      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-round-2",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 3333}]
          })
        ])

      assert %{"results" => [%{"deposit_due_cents" => 2_000}]} = json_response(conn, 200)
    end

    test "rejects a duplicate group identifier", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_group_operation(%{"operation_id" => "op-1002"})
        ])

      assert %{"results" => [_, rejected]} = json_response(conn, 200)

      assert rejected == %{
               "operation_id" => "op-1002",
               "status" => "rejected",
               "code" => "group_already_exists"
             }

      assert %{"revision" => 1} = fetch_group!(conn, "group-81")
    end

    test "rejects a stay with less than one night", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{"arrival_on" => @departure, "departure_on" => @arrival})
        ])

      assert_rejected(conn, "invalid_stay")
    end

    test "rejects a same-day stay", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{"arrival_on" => @arrival, "departure_on" => @arrival})
        ])

      assert_rejected(conn, "invalid_stay")
    end

    test "rejects unusable stay dates", %{conn: conn} do
      for overrides <- [
            %{"arrival_on" => "2026-13-40"},
            %{"departure_on" => "not-a-date"},
            %{"arrival_on" => 20_261_210},
            %{"arrival_on" => "2026-02-30"},
            %{"departure_on" => nil}
          ] do
        conn = post_operations(conn, [open_group_operation(overrides)])
        assert_rejected(conn, "invalid_stay")
      end

      assert ledger(conn) == zeroed_ledger()
    end

    test "rejects rooms that are missing, empty, or malformed", %{conn: conn} do
      for rooms <- [
            nil,
            [],
            "room-a",
            [%{"room_id" => "room-a"}],
            [%{"nightly_rate_cents" => 15_000}],
            [%{"room_id" => "room-a", "nightly_rate_cents" => 0}],
            [%{"room_id" => "room-a", "nightly_rate_cents" => -15_000}],
            [%{"room_id" => "room-a", "nightly_rate_cents" => 150.0}],
            [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}],
            [%{"room_id" => "", "nightly_rate_cents" => 15_000}],
            [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
              %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
            ]
          ] do
        conn = post_operations(conn, [open_group_operation(%{"rooms" => rooms})])
        assert_rejected(conn, "invalid_rooms")
      end

      assert ledger(conn) == zeroed_ledger()
    end

    test "rejects an unknown rate plan", %{conn: conn} do
      for rate_plan <- [nil, "nonrefundable", "flex", ""] do
        conn = post_operations(conn, [open_group_operation(%{"rate_plan" => rate_plan})])
        assert_rejected(conn, "invalid_rate_plan")
      end
    end

    test "a rejected open creates no group", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation(%{"rate_plan" => "mystery"})])

      response = get(conn, "/api/v1/groups/group-81")
      assert json_response(response, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  describe "record_cash_payment" do
    test "applies cash and reports the remaining outstanding deposit", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-1002", "amount_cents" => 5_000})
        ])

      assert %{"results" => [_, payment]} = json_response(conn, 200)

      assert payment == %{
               "operation_id" => "op-1002",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      assert %{"deposit_paid_cents" => 5_000, "outstanding_deposit_cents" => 14_500} =
               fetch_group!(conn, "group-81")
    end

    test "a payment may cover the deposit exactly", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"amount_cents" => 19_500})
        ])

      assert %{"results" => [_, %{"outstanding_deposit_cents" => 0, "revision" => 2}]} =
               json_response(conn, 200)
    end

    test "sees changes made by an earlier operation in the same batch", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 10_000}),
          record_payment_operation(%{"operation_id" => "op-3", "amount_cents" => 9_500})
        ])

      assert %{"results" => [_, _, third]} = json_response(conn, 200)
      assert third["outstanding_deposit_cents"] == 0
      assert third["revision"] == 3
    end

    test "rejects a payment exceeding the outstanding deposit and changes nothing", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 10_000}),
          record_payment_operation(%{"operation_id" => "op-3", "amount_cents" => 10_001})
        ])

      assert %{"results" => [_, _, rejected]} = json_response(conn, 200)

      assert rejected == %{
               "operation_id" => "op-3",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             }

      assert %{"revision" => 2, "deposit_paid_cents" => 10_000} = fetch_group!(conn, "group-81")

      assert ledger(conn) == %{
               "cash_held_cents" => 10_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "rejects unusable payment amounts", %{conn: conn} do
      for amount <- [nil, 0, -5_000, "5000", 5_000.0, 1.5] do
        conn =
          post_operations(conn, [
            open_group_operation(),
            record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => amount})
          ])

        assert_rejected_at(conn, 1, "invalid_amount")
      end
    end

    test "rejects payments for a missing group", %{conn: conn} do
      conn =
        post_operations(conn, [record_payment_operation(%{"group_id" => "no-such-group"})])

      assert_rejected(conn, "group_not_found")
    end

    test "rejects payments to a cancelled group", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"amount_cents" => 5_000}),
          cancel_operation(),
          record_payment_operation(%{"operation_id" => "op-4", "amount_cents" => 5_000})
        ])

      assert %{"results" => [_, _, _, rejected]} = json_response(conn, 200)
      assert rejected["code"] == "group_not_active"
    end
  end

  describe "reschedule_group" do
    test "shifts the whole stay by the same number of days", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          reschedule_operation(%{"operation_id" => "op-1002", "new_arrival_on" => "2026-12-24"})
        ])

      assert %{"results" => [_, reschedule]} = json_response(conn, 200)

      assert reschedule == %{
               "operation_id" => "op-1002",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-24",
               "new_departure_on" => "2026-12-27",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-10",
               "revision" => 2
             }

      group = fetch_group!(conn, "group-81")

      assert %{
               "arrival_on" => "2026-12-24",
               "departure_on" => "2026-12-27",
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "revision" => 2
             } = group
    end

    test "may move the stay earlier while staying after the operation date", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          reschedule_operation(%{"operation_id" => "op-2", "new_arrival_on" => "2026-11-05"})
        ])

      assert %{"results" => [_, %{"new_departure_on" => "2026-11-08", "revision" => 2}]} =
               json_response(conn, 200)
    end

    test "rejects a new arrival on or before the operation date", %{conn: conn} do
      for new_arrival <- ["2026-10-03", "2026-09-01"] do
        conn =
          post_operations(conn, [
            open_group_operation(),
            reschedule_operation(%{"operation_id" => "op-2", "new_arrival_on" => new_arrival})
          ])

        assert %{"results" => [_, %{"code" => "invalid_stay"}]} = json_response(conn, 200)
        assert %{"arrival_on" => @arrival, "revision" => 1} = fetch_group!(conn, "group-81")
      end
    end

    test "rejects unusable new arrival dates", %{conn: conn} do
      for new_arrival <- [nil, "tomorrow", "2026-02-30", 20_261_224] do
        conn =
          post_operations(conn, [
            open_group_operation(),
            reschedule_operation(%{"operation_id" => "op-2", "new_arrival_on" => new_arrival})
          ])

        assert_rejected_at(conn, 1, "invalid_stay")
      end
    end

    test "rejects reschedules for missing or inactive groups", %{conn: conn} do
      conn = post_operations(conn, [reschedule_operation()])

      assert %{"results" => [%{"code" => "group_not_found"}]} = json_response(conn, 200)

      conn =
        post_operations(conn, [
          open_group_operation(),
          cancel_operation(),
          reschedule_operation(%{"operation_id" => "op-3"})
        ])

      assert %{"results" => [_, _, %{"code" => "group_not_active"}]} = json_response(conn, 200)
    end
  end

  describe "cancel_group" do
    test "refunds flexible groups cancelled at least 14 days before arrival", %{conn: conn} do
      # Arrival 2026-12-10; cancelling on 2026-11-26 is exactly 14 days ahead.
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_000}),
          cancel_operation(%{"operation_id" => "op-3", "occurred_on" => "2026-11-26"})
        ])

      assert %{"results" => [_, _, cancellation]} = json_response(conn, 200)

      assert cancellation == %{
               "operation_id" => "op-3",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 5_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      group = fetch_group!(conn, "group-81")

      assert %{
               "status" => "cancelled",
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             } = group

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "retains cash for flexible groups cancelled inside 14 days of arrival", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_000}),
          cancel_operation(%{"operation_id" => "op-3", "occurred_on" => "2026-11-27"})
        ])

      assert %{"results" => [_, _, %{"refunded_cents" => 0, "retained_cents" => 5_000}]} =
               json_response(conn, 200)

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 5_000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "advance_purchase groups are always non-refundable", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
          }),
          record_payment_operation(%{
            "operation_id" => "op-2",
            "group_id" => "group-ap",
            "amount_cents" => 10_000
          }),
          cancel_operation(%{
            "operation_id" => "op-3",
            "group_id" => "group-ap",
            "occurred_on" => "2026-11-01"
          })
        ])

      assert %{"results" => [_, _, %{"refunded_cents" => 0, "retained_cents" => 10_000}]} =
               json_response(conn, 200)

      assert %{"cash_retained_cents" => 10_000} = ledger(conn)
    end

    test "unpaid deposit is no longer due after cancellation", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          cancel_operation()
        ])

      assert %{"results" => [_, %{"refunded_cents" => 0, "retained_cents" => 0, "revision" => 2}]} =
               json_response(conn, 200)

      group = fetch_group!(conn, "group-81")

      assert %{
               "status" => "cancelled",
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0,
               "revision" => 2
             } = group
    end

    test "rejects later payment, reschedule, and cancellation of a cancelled group", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          cancel_operation(),
          record_payment_operation(%{"operation_id" => "op-3", "amount_cents" => 1_000}),
          reschedule_operation(%{"operation_id" => "op-4"}),
          cancel_operation(%{"operation_id" => "op-5"})
        ])

      assert %{"results" => [_, _, payment, reschedule, again]} = json_response(conn, 200)

      assert payment["code"] == "group_not_active"
      assert reschedule["code"] == "group_not_active"
      assert again["code"] == "group_not_active"
      assert %{"revision" => 2} = fetch_group!(conn, "group-81")
    end

    test "rejects cancellations for missing groups", %{conn: conn} do
      conn = post_operations(conn, [cancel_operation()])

      assert %{"results" => [%{"code" => "group_not_found"}]} = json_response(conn, 200)
    end
  end

  describe "revisions" do
    test "every applied operation increments the revision exactly once", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 1_000}),
          reschedule_operation(%{"operation_id" => "op-3"}),
          cancel_operation(%{"operation_id" => "op-4"})
        ])

      assert %{"results" => [open, payment, reschedule, cancellation]} = json_response(conn, 200)

      assert open["revision"] == 1
      assert payment["revision"] == 2
      assert reschedule["revision"] == 3
      assert cancellation["revision"] == 4
    end

    test "rejected operations do not increment the revision", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 99_999}),
          record_payment_operation(%{"operation_id" => "op-3", "amount_cents" => 0}),
          reschedule_operation(%{"operation_id" => "op-4", "new_arrival_on" => "2020-01-01"}),
          open_group_operation(%{"operation_id" => "op-5"}),
          record_payment_operation(%{"operation_id" => "op-6", "amount_cents" => 1_000})
        ])

      assert %{"results" => [_open, first, second, third, _fourth, fifth]} =
               json_response(conn, 200)

      assert first["code"] == "payment_exceeds_outstanding"
      assert second["code"] == "invalid_amount"
      assert third["code"] == "invalid_stay"

      assert fifth["status"] == "applied"
      assert fifth["revision"] == 2
    end
  end

  describe "expected_revision" do
    test "applies when it equals the revision immediately before the operation", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{
            "operation_id" => "op-2",
            "amount_cents" => 5_000,
            "expected_revision" => 1
          }),
          record_payment_operation(%{
            "operation_id" => "op-3",
            "amount_cents" => 14_500,
            "expected_revision" => 2
          })
        ])

      assert %{"results" => [_, second, third]} = json_response(conn, 200)
      assert second["status"] == "applied"
      assert third["status"] == "applied"
      assert third["revision"] == 3
      assert %{"outstanding_deposit_cents" => 0} = fetch_group!(conn, "group-81")
    end

    test "rejects a mismatch before other domain validation", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{
            "operation_id" => "op-2",
            "amount_cents" => 99_999,
            "expected_revision" => 7
          })
        ])

      assert %{"results" => [_, rejected]} = json_response(conn, 200)

      assert rejected == %{
               "operation_id" => "op-2",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 7,
               "actual_revision" => 1
             }

      assert %{"revision" => 1, "deposit_paid_cents" => 0} = fetch_group!(conn, "group-81")
    end

    test "sees changes made by earlier operations in the same batch", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_000}),
          record_payment_operation(%{
            "operation_id" => "op-3",
            "amount_cents" => 5_000,
            "expected_revision" => 1
          }),
          record_payment_operation(%{
            "operation_id" => "op-4",
            "amount_cents" => 9_500,
            "expected_revision" => 2
          })
        ])

      assert %{"results" => [_, _, third, fourth]} = json_response(conn, 200)

      assert third == %{
               "operation_id" => "op-3",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert fourth["status"] == "applied"
      assert fourth["revision"] == 3
    end

    test "resolves group existence before comparing revisions", %{conn: conn} do
      for op <- [
            record_payment_operation(%{"group_id" => "missing", "expected_revision" => 1}),
            reschedule_operation(%{"group_id" => "missing", "expected_revision" => 1}),
            cancel_operation(%{"group_id" => "missing", "expected_revision" => 1})
          ] do
        conn = post_operations(conn, [op])
        assert %{"results" => [%{"code" => "group_not_found"}]} = json_response(conn, 200)
      end
    end

    test "a stale revision beats an inactive group", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          cancel_operation(),
          record_payment_operation(%{
            "operation_id" => "op-3",
            "amount_cents" => 5_000,
            "expected_revision" => 1
          })
        ])

      assert %{"results" => [_, _, rejected]} = json_response(conn, 200)
      assert rejected["code"] == "stale_revision"
      assert rejected["actual_revision"] == 2
    end

    test "omitting expected_revision preserves unconditional behavior", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_000})
        ])

      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)
    end
  end

  describe "batch failures" do
    test "unknown operation types are rejected with invalid_operation", %{conn: conn} do
      conn =
        post_operations(conn, [
          %{"operation_id" => "op-1", "type" => "open_confidence", "group_id" => "group-81"},
          %{"operation_id" => "op-2"}
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "rejected"))
      assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    end

    test "operations missing identifying data are rejected with invalid_operation", %{conn: conn} do
      for op <- [
            %{"operation_id" => "op-1", "type" => "open_group", "occurred_on" => @occurred_on},
            %{
              "operation_id" => "op-2",
              "type" => "record_cash_payment",
              "occurred_on" => @occurred_on
            },
            %{
              "type" => "record_cash_payment",
              "group_id" => "group-81",
              "occurred_on" => @occurred_on
            },
            %{
              "operation_id" => "op-4",
              "type" => "record_cash_payment",
              "group_id" => "group-81"
            },
            %{
              "operation_id" => "op-5",
              "type" => "record_cash_payment",
              "group_id" => "group-81",
              "occurred_on" => "2026-13-01"
            },
            "open_group",
            42
          ] do
        conn = post_operations(conn, [op])
        assert %{"results" => [result]} = json_response(conn, 200)
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end
    end

    test "open_group requires the partner identifiers it applies", %{conn: conn} do
      for op <- [
            open_group_operation(%{"guest_id" => nil}),
            open_group_operation(%{"property_id" => ""})
          ] do
        conn = post_operations(conn, [op])
        assert_rejected(conn, "invalid_operation")
      end
    end

    test "a missing operation_id is rejected with a null operation_id", %{conn: conn} do
      conn =
        post_operations(conn, [
          %{
            "type" => "record_cash_payment",
            "group_id" => "group-81",
            "occurred_on" => @occurred_on,
            "amount_cents" => 100
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
               ]
             } =
               json_response(conn, 200)
    end

    test "rejected operations leave the ledger untouched", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"amount_cents" => -1}),
          cancel_operation()
        ])

      assert %{"results" => [_, rejected, _]} = json_response(conn, 200)
      assert rejected["code"] == "invalid_amount"
      assert ledger(conn) == zeroed_ledger()
    end
  end

  describe "policy versions" do
    test "flexible groups booked before 2027-01-01 keep the 14-day window", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-2026",
            "occurred_on" => "2026-12-31",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          })
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert %{"policy_version" => "flex-14", "refundable_until" => "2027-03-01"} =
               fetch_group!(conn, "group-2026")
    end

    test "flexible groups booked on or after 2027-01-01 use the 30-day window", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-2027",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          })
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert %{"policy_version" => "flex-30", "refundable_until" => "2027-02-13"} =
               fetch_group!(conn, "group-2027")
    end

    test "advance_purchase groups are never refundable", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase",
            "occurred_on" => "2027-01-01",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
          })
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert %{"policy_version" => "advance-nonrefundable", "refundable_until" => nil} =
               fetch_group!(conn, "group-ap")
    end

    test "rescheduling never moves a group to a newer policy and recomputes refundable_until", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          reschedule_operation(%{"operation_id" => "op-2", "new_arrival_on" => "2027-01-04"})
        ])

      assert %{"results" => [_, reschedule]} = json_response(conn, 200)

      assert %{"policy_version" => "flex-14", "refundable_until" => "2026-12-21"} = reschedule

      assert %{
               "booked_on" => "2026-10-03",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-21"
             } = fetch_group!(conn, "group-81")
    end

    test "a flex-30 group is refundable through the 30th day before arrival only", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-win-1",
            "occurred_on" => "2027-01-05",
            "arrival_on" => "2027-03-31",
            "departure_on" => "2027-04-03"
          }),
          open_group_operation(%{
            "operation_id" => "op-2",
            "group_id" => "group-win-2",
            "occurred_on" => "2027-01-05",
            "arrival_on" => "2027-03-31",
            "departure_on" => "2027-04-03"
          }),
          record_payment_operation(%{
            "operation_id" => "op-3",
            "group_id" => "group-win-1",
            "amount_cents" => 5_000
          }),
          record_payment_operation(%{
            "operation_id" => "op-4",
            "group_id" => "group-win-2",
            "amount_cents" => 5_000
          }),
          cancel_operation(%{
            "operation_id" => "op-5",
            "group_id" => "group-win-1",
            "occurred_on" => "2027-03-10"
          }),
          cancel_operation(%{
            "operation_id" => "op-6",
            "group_id" => "group-win-2",
            "occurred_on" => "2027-03-01"
          })
        ])

      assert %{"results" => [_, _, _, _, inside, through]} = json_response(conn, 200)

      # 21 days ahead: refundable under the old 14-day window, not under flex-30.
      assert %{"refunded_cents" => 0, "retained_cents" => 5_000} = inside
      # Exactly 30 days ahead: refundable.
      assert %{"refunded_cents" => 5_000, "retained_cents" => 0} = through
    end
  end

  describe "cancel_group refund methods" do
    test "hotel credit on a refundable cancellation issues a lot worth 110% of the cash", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 10_000}),
          cancel_operation(%{
            "operation_id" => "op-3",
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => [_, _, cancellation]} = json_response(conn, 200)

      assert cancellation == %{
               "operation_id" => "op-3",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_000,
               "revision" => 3
             }

      assert %{
               "status" => "cancelled",
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             } = fetch_group!(conn, "group-81")

      assert %{
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-3",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-21"
                 }
               ]
             } = guest_credit(conn, "guest-22", "2027-11-20")

      # The lot expired the day before: it is no longer available.
      assert %{"available_cents" => 0, "lots" => []} =
               guest_credit(conn, "guest-22", "2027-11-21")

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 11_000
             }
    end

    test "applies the standard rounding rule to the 10% bonus", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_555}),
          cancel_operation(%{
            "operation_id" => "op-3",
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => [_, _, %{"credit_issued_cents" => 6_111}]} = json_response(conn, 200)
    end

    test "a refundable hotel-credit cancellation without cash issues no credit", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          cancel_operation(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
        ])

      assert %{
               "results" => [
                 _,
                 %{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 0}
               ]
             } =
               json_response(conn, 200)

      assert %{"available_cents" => 0, "lots" => []} = guest_credit(conn, "guest-22")
    end

    test "an explicit cash refund_method refunds as before", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_000}),
          cancel_operation(%{
            "operation_id" => "op-3",
            "occurred_on" => "2026-11-26",
            "refund_method" => "cash"
          })
        ])

      assert %{"results" => [_, _, %{"refunded_cents" => 5_000, "credit_issued_cents" => 0}]} =
               json_response(conn, 200)

      assert %{"cash_refunded_cents" => 5_000, "cash_converted_to_credit_cents" => 0} =
               ledger(conn)
    end

    test "rejects hotel credit for a non-refundable cancellation and leaves the group active", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_000}),
          cancel_operation(%{
            "operation_id" => "op-3",
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => [_, _, rejected]} = json_response(conn, 200)

      assert rejected == %{
               "operation_id" => "op-3",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      assert %{"status" => "active", "revision" => 2, "deposit_paid_cents" => 5_000} =
               fetch_group!(conn, "group-81")

      assert %{"cash_held_cents" => 5_000, "cash_converted_to_credit_cents" => 0} = ledger(conn)
    end

    test "rejects hotel credit for advance_purchase groups", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
          }),
          record_payment_operation(%{
            "operation_id" => "op-2",
            "group_id" => "group-ap",
            "amount_cents" => 10_000
          }),
          cancel_operation(%{
            "operation_id" => "op-3",
            "group_id" => "group-ap",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => [_, _, %{"code" => "refund_method_not_available"}]} =
               json_response(conn, 200)

      assert %{"status" => "active"} = fetch_group!(conn, "group-ap")
    end

    test "rejects an unknown refund method as invalid_operation", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          cancel_operation(%{"refund_method" => "store_credit"})
        ])

      assert %{"results" => [_, %{"code" => "invalid_operation"}]} = json_response(conn, 200)
      assert %{"status" => "active", "revision" => 1} = fetch_group!(conn, "group-81")
    end

    test "a stale revision is rejected before the refund method", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
          }),
          cancel_operation(%{
            "operation_id" => "op-2",
            "group_id" => "group-ap",
            "expected_revision" => 7,
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => [_, %{"code" => "stale_revision"}]} = json_response(conn, 200)
    end
  end

  describe "apply_hotel_credit" do
    test "applies the guest's credit to the outstanding deposit", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 4_000
              })
            ]
        )

      assert %{"results" => [_, _, _, _, apply]} = json_response(conn, 200)

      assert apply == %{
               "operation_id" => "op-apply",
               "status" => "applied",
               "group_id" => "group-target",
               "amount_cents" => 4_000,
               "outstanding_deposit_cents" => 15_500,
               "revision" => 2
             }

      assert %{
               "deposit_paid_cents" => 4_000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 4_000,
               "outstanding_deposit_cents" => 15_500
             } = fetch_group!(conn, "group-target")

      # Applied credit is no longer available but stays a liability.
      assert %{"available_cents" => 7_000, "lots" => [%{"remaining_cents" => 7_000}]} =
               guest_credit(conn, "guest-22", "2027-11-20")

      assert %{"credit_liability_cents" => 11_000} = ledger(conn, on: "2027-11-20")
    end

    test "funds a deposit with both cash and credit", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              }),
              record_payment_operation(%{
                "operation_id" => "op-pay-target",
                "group_id" => "group-target",
                "amount_cents" => 5_000
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 4_000
              }),
              # Cash paid after credit still respects the combined outstanding.
              record_payment_operation(%{
                "operation_id" => "op-pay-again",
                "group_id" => "group-target",
                "amount_cents" => 1_000
              })
            ]
        )

      assert %{"results" => [_, _, _, _, _, _, payment_after]} = json_response(conn, 200)
      assert %{"outstanding_deposit_cents" => 9_500} = payment_after

      assert %{
               "deposit_paid_cents" => 10_000,
               "cash_paid_cents" => 6_000,
               "credit_paid_cents" => 4_000,
               "outstanding_deposit_cents" => 9_500,
               "revision" => 4
             } = fetch_group!(conn, "group-target")
    end

    test "consumes lots by earliest expiry, then by source operation", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-old", "op-cancel-old", 3_000, "2025-12-31") ++
            convert_cash_to_credit("group-new", "op-cancel-new", 5_000, "2026-11-20") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 5_000
              })
            ]
        )

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The 2027-01-01 lot was exhausted first; the rest came from the lot
      # expiring 2027-11-21.
      assert %{
               "available_cents" => 3_800,
               "lots" => [
                 %{"source_operation_id" => "op-cancel-new", "remaining_cents" => 3_800}
               ]
             } = guest_credit(conn, "guest-22")
    end

    test "consumes lots with equal expiries by source operation", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-aaa", "op-cancel-aaa", 2_000, "2025-12-31") ++
            convert_cash_to_credit("group-bbb", "op-cancel-bbb", 2_000, "2025-12-31") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 2_200
              })
            ]
        )

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "available_cents" => 2_200,
               "lots" => [
                 %{"source_operation_id" => "op-cancel-bbb", "remaining_cents" => 2_200}
               ]
             } = guest_credit(conn, "guest-22")
    end

    test "rejects applying more credit than the guest has without consuming any", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 11_001
              })
            ]
        )

      assert %{"results" => [_, _, _, _, %{"code" => "insufficient_credit"}]} =
               json_response(conn, 200)

      assert %{"revision" => 1, "deposit_paid_cents" => 0} = fetch_group!(conn, "group-target")

      assert %{"available_cents" => 11_000} = guest_credit(conn, "guest-22")
    end

    test "rejects credit exceeding the outstanding deposit", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target",
                "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 10_000
              })
            ]
        )

      # The single-room group's deposit is 9_000, below the 10_000 requested
      # and below the 11_000 of available credit.
      assert %{"results" => [_, _, _, _, %{"code" => "payment_exceeds_outstanding"}]} =
               json_response(conn, 200)
    end

    test "credit may not exceed the deposit left after cash payments", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{"operation_id" => "op-open-81", "group_id" => "group-81"}),
              record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 15_000}),
              apply_credit_operation(%{"operation_id" => "op-3", "amount_cents" => 5_000}),
              apply_credit_operation(%{"operation_id" => "op-4", "amount_cents" => 4_500})
            ]
        )

      assert %{"results" => [_, _, _, _, _, rejected, applied]} = json_response(conn, 200)

      assert rejected["code"] == "payment_exceeds_outstanding"
      assert %{"outstanding_deposit_cents" => 0, "revision" => 3} = applied
    end

    test "rejects unusable credit amounts", %{conn: conn} do
      for amount <- [nil, 0, -5_000, "5000", 5_000.0] do
        conn =
          post_operations(conn, [
            open_group_operation(),
            apply_credit_operation(%{"operation_id" => "op-2", "amount_cents" => amount})
          ])

        assert_rejected_at(conn, 1, "invalid_amount")
      end
    end

    test "rejects credit for missing or inactive groups", %{conn: conn} do
      conn = post_operations(conn, [apply_credit_operation(%{"group_id" => "missing"})])

      assert_rejected(conn, "group_not_found")

      conn =
        post_operations(conn, [
          open_group_operation(),
          cancel_operation(),
          apply_credit_operation(%{"operation_id" => "op-3"})
        ])

      assert %{"results" => [_, _, %{"code" => "group_not_active"}]} = json_response(conn, 200)
    end

    test "follows the revision contract", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply-1",
                "group_id" => "group-target",
                "amount_cents" => 1_000,
                "expected_revision" => 1
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply-2",
                "group_id" => "group-target",
                "amount_cents" => 1_000,
                "expected_revision" => 2
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply-3",
                "group_id" => "group-target",
                "amount_cents" => 1_000,
                "expected_revision" => 2
              })
            ]
        )

      assert %{"results" => [_, _, _, _, second, third, stale]} = json_response(conn, 200)

      assert second["revision"] == 2
      assert third["revision"] == 3

      assert stale == %{
               "operation_id" => "op-apply-3",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-target",
               "expected_revision" => 2,
               "actual_revision" => 3
             }
    end

    test "a stale revision is rejected before insufficient credit", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          apply_credit_operation(%{
            "operation_id" => "op-2",
            "amount_cents" => 999_999,
            "expected_revision" => 7
          })
        ])

      assert %{"results" => [_, %{"code" => "stale_revision"}]} = json_response(conn, 200)
    end

    test "a rejected application does not advance the revision", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{"operation_id" => "op-open-81", "group_id" => "group-81"}),
              # 19_500 is within the outstanding deposit but above the 11_000
              # of credit the guest holds.
              apply_credit_operation(%{"operation_id" => "op-2", "amount_cents" => 19_500}),
              apply_credit_operation(%{"operation_id" => "op-3", "amount_cents" => 1_000})
            ]
        )

      assert %{"results" => [_, _, _, _, rejected, applied]} = json_response(conn, 200)

      assert rejected["code"] == "insufficient_credit"
      assert %{"revision" => 2, "amount_cents" => 1_000} = applied
    end

    test "evaluates lot expiry using the operation's occurred_on date", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 3_000, "2025-12-31") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              })
            ]
        )

      # The lot expires on 2027-01-01, so it cannot fund an application dated
      # on its expiry date.
      conn =
        post_operations(conn, [
          apply_credit_operation(%{
            "operation_id" => "op-apply-late",
            "group_id" => "group-target",
            "amount_cents" => 3_300,
            "occurred_on" => "2027-01-01"
          })
        ])

      assert %{"results" => [%{"code" => "insufficient_credit"}]} = json_response(conn, 200)

      # One day earlier it can still fund the deposit.
      conn =
        post_operations(conn, [
          apply_credit_operation(%{
            "operation_id" => "op-apply-early",
            "group_id" => "group-target",
            "amount_cents" => 3_300,
            "occurred_on" => "2026-12-31"
          })
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)
    end
  end

  describe "settling groups funded by credit" do
    test "a refundable cash cancellation restores applied credit to its original lot and expiry",
         %{
           conn: conn
         } do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              }),
              record_payment_operation(%{
                "operation_id" => "op-pay-target",
                "group_id" => "group-target",
                "amount_cents" => 5_000
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 4_000
              }),
              cancel_operation(%{
                "operation_id" => "op-cancel-target",
                "group_id" => "group-target",
                "occurred_on" => "2026-11-26"
              })
            ]
        )

      assert %{"results" => [_, _, _, _, _, _, cancellation]} = json_response(conn, 200)

      assert %{"refunded_cents" => 5_000, "retained_cents" => 0, "credit_issued_cents" => 0} =
               cancellation

      assert %{
               "status" => "cancelled",
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             } = fetch_group!(conn, "group-target")

      # The original lot is whole again, with its original expiry and no
      # second bonus.
      assert %{
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-source",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-21"
                 }
               ]
             } = guest_credit(conn, "guest-22", "2027-11-20")

      assert ledger(conn, on: "2027-11-20") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 11_000
             }
    end

    test "a refundable hotel-credit cancellation restores applied credit and issues a new lot", %{
      conn: conn
    } do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              }),
              record_payment_operation(%{
                "operation_id" => "op-pay-target",
                "group_id" => "group-target",
                "amount_cents" => 5_000
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 4_000
              }),
              cancel_operation(%{
                "operation_id" => "op-cancel-target",
                "group_id" => "group-target",
                "occurred_on" => "2026-11-26",
                "refund_method" => "hotel_credit"
              })
            ]
        )

      assert %{"results" => [_, _, _, _, _, _, cancellation]} = json_response(conn, 200)

      assert %{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 5_500} =
               cancellation

      assert %{
               "available_cents" => 16_500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-source",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-21"
                 },
                 %{
                   "source_operation_id" => "op-cancel-target",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-11-27"
                 }
               ]
             } = guest_credit(conn, "guest-22", "2027-11-20")

      assert ledger(conn, on: "2027-11-20") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 15_000,
               "credit_liability_cents" => 16_500
             }
    end

    test "a non-refundable cancellation retains cash and consumes applied credit", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 10_000, "2026-11-20") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target"
              }),
              record_payment_operation(%{
                "operation_id" => "op-pay-target",
                "group_id" => "group-target",
                "amount_cents" => 5_000
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 4_000
              }),
              cancel_operation(%{
                "operation_id" => "op-cancel-target",
                "group_id" => "group-target",
                "occurred_on" => "2026-11-27"
              })
            ]
        )

      assert %{"results" => [_, _, _, _, _, _, cancellation]} = json_response(conn, 200)

      assert %{"refunded_cents" => 0, "retained_cents" => 5_000, "credit_issued_cents" => 0} =
               cancellation

      assert %{"status" => "cancelled", "credit_paid_cents" => 0} =
               fetch_group!(conn, "group-target")

      assert %{"available_cents" => 7_000} = guest_credit(conn, "guest-22", "2027-11-20")

      assert ledger(conn, on: "2027-11-20") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 5_000,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 7_000
             }
    end

    test "credit restored to an already expired lot expires immediately", %{conn: conn} do
      conn =
        post_operations(
          conn,
          convert_cash_to_credit("group-source", "op-cancel-source", 3_000, "2025-12-31") ++
            [
              open_group_operation(%{
                "operation_id" => "op-open-target",
                "group_id" => "group-target",
                "occurred_on" => "2026-06-01",
                "arrival_on" => "2027-03-01",
                "departure_on" => "2027-03-04"
              }),
              apply_credit_operation(%{
                "operation_id" => "op-apply",
                "group_id" => "group-target",
                "amount_cents" => 3_300
              })
            ]
        )

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The lot expired on 2027-01-01; while it funds the active target the
      # applied amount remains a liability.
      assert %{"credit_liability_cents" => 3_300} = ledger(conn, on: "2027-02-01")

      conn =
        post_operations(conn, [
          cancel_operation(%{
            "operation_id" => "op-cancel-target",
            "group_id" => "group-target",
            "occurred_on" => "2027-02-01"
          })
        ])

      assert %{
               "results" => [
                 %{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 0}
               ]
             } =
               json_response(conn, 200)

      assert %{"credit_liability_cents" => 0} = ledger(conn, on: "2027-02-01")

      assert %{"available_cents" => 0, "lots" => []} =
               guest_credit(conn, "guest-22", "2027-02-01")
    end
  end

  defp record_payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => @occurred_on,
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp reschedule_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-reschedule",
        "type" => "reschedule_group",
        "occurred_on" => @occurred_on,
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-24"
      },
      overrides
    )
  end

  defp cancel_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-25",
        "group_id" => "group-81",
        "amount_cents" => 4_000
      },
      overrides
    )
  end

  defp convert_cash_to_credit(group_id, operation_id, cash_cents, occurred_on) do
    [
      open_group_operation(%{"group_id" => group_id}),
      record_payment_operation(%{
        "group_id" => group_id,
        "operation_id" => operation_id <> "-pay",
        "amount_cents" => cash_cents
      }),
      cancel_operation(%{
        "group_id" => group_id,
        "operation_id" => operation_id,
        "occurred_on" => occurred_on,
        "refund_method" => "hotel_credit"
      })
    ]
  end

  defp assert_rejected(conn, code), do: assert_rejected_at(conn, 0, code)

  defp assert_rejected_at(conn, index, code) do
    assert %{"results" => results} = json_response(conn, 200)
    result = Enum.at(results, index)
    assert result["status"] == "rejected"
    assert result["code"] == code
  end

  defp ledger(conn, opts \\ []) do
    query = if on = opts[:on], do: "?on=#{on}", else: ""
    assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger#{query}"), 200)
    data
  end

  defp guest_credit(conn, guest_id, on \\ nil) do
    query = if on, do: "?on=#{on}", else: ""

    assert %{"data" => data} =
             json_response(get(conn, "/api/v1/guests/#{guest_id}/credit#{query}"), 200)

    data
  end

  defp zeroed_ledger do
    %{
      "cash_held_cents" => 0,
      "cash_refunded_cents" => 0,
      "cash_retained_cents" => 0,
      "cash_converted_to_credit_cents" => 0,
      "credit_liability_cents" => 0
    }
  end
end
