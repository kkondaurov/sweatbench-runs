defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: true

  @occurred_on "2026-10-03"
  @arrival_on "2026-12-10"
  @departure_on "2026-12-13"

  defp open_operation(group_id) do
    %{
      "operation_id" => "op-open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => @occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => @arrival_on,
      "departure_on" => @departure_on,
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
      ]
    }
  end

  defp payment_operation(group_id, amount_cents, expected_revision \\ nil) do
    operation = %{
      "operation_id" => "op-pay-#{group_id}-#{amount_cents}",
      "type" => "record_cash_payment",
      "occurred_on" => @occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }

    maybe_put_expected_revision(operation, expected_revision)
  end

  defp reschedule_operation(group_id, new_arrival_on, expected_revision \\ nil) do
    operation = %{
      "operation_id" => "op-move-#{group_id}",
      "type" => "reschedule_group",
      "occurred_on" => @occurred_on,
      "group_id" => group_id,
      "new_arrival_on" => new_arrival_on
    }

    maybe_put_expected_revision(operation, expected_revision)
  end

  defp cancel_operation(group_id, occurred_on \\ @occurred_on, expected_revision \\ nil) do
    operation = %{
      "operation_id" => "op-cancel-#{group_id}",
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    maybe_put_expected_revision(operation, expected_revision)
  end

  defp maybe_put_expected_revision(operation, nil), do: operation

  defp maybe_put_expected_revision(operation, revision),
    do: Map.put(operation, "expected_revision", revision)

  defp submit!(conn, operations) do
    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    assert conn.status == 200
    json_response(conn, 200)["results"]
  end

  defp open_group!(conn, group_id, adjust \\ fn x -> x end) do
    operation = adjust.(open_operation(group_id))
    [result] = submit!(conn, [operation])
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp group_data(conn, group_id) do
    conn = get(conn, "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp ledger(conn) do
    conn = get(conn, "/api/v1/ledger")
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  describe "batch envelope" do
    test "returns one result per operation in order" do
      conn = build_conn()
      results = submit!(conn, [open_operation("g-1"), open_operation("g-2")])

      assert Enum.map(results, & &1["group_id"]) == ["g-1", "g-2"]
      assert Enum.map(results, & &1["status"]) == ["applied", "applied"]
    end

    test "an empty operations array is a valid batch" do
      conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => []})
      assert json_response(conn, 200) == %{"results" => []}
    end

    test "rejects a body without an operations array with 422 invalid_batch" do
      conn = post(build_conn(), "/api/v1/partner-batches", %{})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

      conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => %{}})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

      conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => nil})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "later operations continue after a rejection and earlier work persists" do
      conn = build_conn()

      results =
        submit!(conn, [
          %{"type" => "nonsense", "occurred_on" => @occurred_on},
          open_operation("g-keep"),
          payment_operation("g-keep", 1000)
        ])

      assert Enum.map(results, & &1["status"]) == ["rejected", "applied", "applied"]
      assert Enum.at(results, 0)["code"] == "invalid_operation"

      assert group_data(conn, "g-keep")["deposit_paid_cents"] == 1000
    end
  end

  describe "open_group" do
    test "applies the API example and reports deposit and revision 1" do
      conn = build_conn()

      assert [result] = submit!(conn, [open_operation("group-81")])

      assert result == %{
               "operation_id" => "op-open-group-81",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
               "revision" => 1
             }
    end

    test "advance_purchase deposits the full lodging amount" do
      conn = build_conn()

      result =
        open_group!(conn, "g-ap", fn operation ->
          %{operation | "rate_plan" => "advance_purchase"}
        end)

      assert result["deposit_due_cents"] == 97_500
    end

    test "flexible deposits round each room separately, half cents upward" do
      conn = build_conn()

      result =
        open_group!(conn, "g-round", fn operation ->
          %{
            operation
            | "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-11",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 25_001},
                %{"room_id" => "room-b", "nightly_rate_cents" => 25_002}
              ]
          }
        end)

      # Round each room (5000.2 -> 5000, 5000.4 -> 5000) rather than the total
      # (50003 * 20% = 10000.6 -> 10001).
      assert result["deposit_due_cents"] == 10_000
    end

    test "flexible percentages round to the nearest cent, upward at half" do
      conn = build_conn()

      result =
        open_group!(conn, "g-round-up", fn operation ->
          %{
            operation
            | "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-11",
              "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 3333}]
          }
        end)

      # 3333 * 20% = 666.6 -> 667
      assert result["deposit_due_cents"] == 667
    end

    test "rejects a duplicate group identifier without changing the group" do
      conn = build_conn()
      open_group!(conn, "g-dup")

      assert [result] = submit!(conn, [open_operation("g-dup")])
      assert result["status"] == "rejected"
      assert result["code"] == "group_already_exists"
      assert result["operation_id"] == "op-open-g-dup"

      assert group_data(conn, "g-dup")["revision"] == 1
    end

    test "rejects unusable stays with invalid_stay" do
      conn = build_conn()

      invalid_operations = [
        Map.merge(open_operation("g-stay"), %{
          "arrival_on" => @arrival_on,
          "departure_on" => @arrival_on
        }),
        Map.merge(open_operation("g-stay"), %{
          "arrival_on" => @arrival_on,
          "departure_on" => "2026-12-09"
        }),
        Map.delete(open_operation("g-stay"), "arrival_on"),
        Map.delete(open_operation("g-stay"), "departure_on"),
        Map.merge(open_operation("g-stay"), %{"arrival_on" => "not-a-date"}),
        Map.merge(open_operation("g-stay"), %{"arrival_on" => 12_010})
      ]

      for operation <- invalid_operations do
        assert [result] = submit!(conn, [operation])
        assert result["code"] == "invalid_stay", inspect(result)
      end
    end

    test "rejects unusable rooms with invalid_rooms" do
      conn = build_conn()

      for rooms <- [
            [],
            [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
              %{"room_id" => "room-a", "nightly_rate_cents" => 16000}
            ],
            [%{"nightly_rate_cents" => 15000}],
            [%{"room_id" => "room-a"}],
            [%{"room_id" => "room-a", "nightly_rate_cents" => -1}],
            [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}],
            [%{"room_id" => "", "nightly_rate_cents" => 15000}]
          ] do
        assert [result] =
                 submit!(conn, [Map.put(open_operation("g-rooms"), "rooms", rooms)])

        assert result["code"] == "invalid_rooms", inspect(result)
      end

      assert [result] = submit!(conn, [Map.delete(open_operation("g-rooms"), "rooms")])
      assert result["code"] == "invalid_rooms"
    end

    test "rejects unknown rate plans with invalid_rate_plan" do
      conn = build_conn()

      for plan <- ["corp", "", nil] do
        assert [result] =
                 submit!(conn, [Map.put(open_operation("g-plan"), "rate_plan", plan)])

        assert result["code"] == "invalid_rate_plan", inspect(result)
      end

      assert [result] = submit!(conn, [Map.delete(open_operation("g-plan"), "rate_plan")])
      assert result["code"] == "invalid_rate_plan"
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit and bumps the revision" do
      conn = build_conn()
      open_group!(conn, "g-pay")

      assert [result] = submit!(conn, [payment_operation("g-pay", 5000)])

      assert result == %{
               "operation_id" => "op-pay-g-pay-5000",
               "status" => "applied",
               "group_id" => "g-pay",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      assert ledger(conn)["cash_held_cents"] == 5000
    end

    test "pays off the deposit entirely" do
      conn = build_conn()
      open_group!(conn, "g-full")

      assert [result] = submit!(conn, [payment_operation("g-full", 19_500)])
      assert result["outstanding_deposit_cents"] == 0

      assert [later] = submit!(conn, [payment_operation("g-full", 1)])
      assert later["code"] == "payment_exceeds_outstanding"
      assert later["status"] == "rejected"
    end

    test "rejects amounts that are not usable payments" do
      conn = build_conn()
      open_group!(conn, "g-amount")

      for amount <- [0, -100, "500", 500.5, nil] do
        assert [result] =
                 submit!(conn, [Map.put(payment_operation("g-amount", 1), "amount_cents", amount)])

        assert result["code"] == "invalid_amount", inspect(result)
      end

      assert [result] =
               submit!(conn, [Map.delete(payment_operation("g-amount", 1), "amount_cents")])

      assert result["code"] == "invalid_amount"

      assert group_data(conn, "g-amount")["deposit_paid_cents"] == 0
      assert ledger(conn)["cash_held_cents"] == 0
    end

    test "rejects a payment that exceeds the outstanding deposit" do
      conn = build_conn()
      open_group!(conn, "g-exceed")

      assert [result] = submit!(conn, [payment_operation("g-exceed", 19_501)])
      assert result["code"] == "payment_exceeds_outstanding"

      assert group_data(conn, "g-exceed")["deposit_paid_cents"] == 0
      assert group_data(conn, "g-exceed")["revision"] == 1
    end

    test "rejects a payment for a missing group with group_not_found" do
      conn = build_conn()

      assert [result] = submit!(conn, [payment_operation("g-missing", 500)])
      assert result["code"] == "group_not_found"
    end
  end

  describe "reschedule_group" do
    test "shifts arrival and departure by the same number of days" do
      conn = build_conn()
      open_group!(conn, "g-move")

      assert [result] = submit!(conn, [reschedule_operation("g-move", "2026-12-17")])

      assert result == %{
               "operation_id" => "op-move-g-move",
               "status" => "applied",
               "group_id" => "g-move",
               "new_arrival_on" => "2026-12-17",
               "new_departure_on" => "2026-12-20",
               "revision" => 2
             }

      data = group_data(conn, "g-move")
      assert data["arrival_on"] == "2026-12-17"
      assert data["departure_on"] == "2026-12-20"
      assert data["lodging_total_cents"] == 97_500
      assert data["deposit_due_cents"] == 19_500
    end

    test "increments the revision even when the visible dates do not change" do
      conn = build_conn()
      open_group!(conn, "g-same")

      assert [result] = submit!(conn, [reschedule_operation("g-same", @arrival_on)])
      assert result["status"] == "applied"
      assert result["revision"] == 2
      assert result["new_arrival_on"] == @arrival_on
      assert result["new_departure_on"] == @departure_on
    end

    test "rejects unusable arrivals with invalid_stay" do
      conn = build_conn()
      open_group!(conn, "g-dates")

      for arrival <- [@occurred_on, "2026-10-02", "not-a-date", nil] do
        assert [result] =
                 submit!(conn, [
                   Map.put(
                     reschedule_operation("g-dates", "2026-12-17"),
                     "new_arrival_on",
                     arrival
                   )
                 ])

        assert result["code"] == "invalid_stay", inspect(result)
      end

      assert [result] =
               submit!(conn, [
                 Map.delete(reschedule_operation("g-dates", "2026-12-17"), "new_arrival_on")
               ])

      assert result["code"] == "invalid_stay"

      assert group_data(conn, "g-dates")["revision"] == 1
    end

    test "rejects a move for a missing group with group_not_found" do
      conn = build_conn()

      assert [result] = submit!(conn, [reschedule_operation("g-missing", "2026-12-17")])
      assert result["code"] == "group_not_found"
    end
  end

  describe "cancel_group" do
    test "refunds cash when a flexible group is cancelled at least 14 days before arrival" do
      conn = build_conn()
      open_group!(conn, "g-refund")
      submit!(conn, [payment_operation("g-refund", 5000)])

      # 2026-12-10 minus 14 days is 2026-11-26.
      assert [result] = submit!(conn, [cancel_operation("g-refund", "2026-11-26")])

      assert result == %{
               "operation_id" => "op-cancel-g-refund",
               "status" => "applied",
               "group_id" => "g-refund",
               "refunded_cents" => 5000,
               "retained_cents" => 0,
               "revision" => 3
             }

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5000,
               "cash_retained_cents" => 0
             }
    end

    test "retains cash when a flexible group is cancelled 13 days before arrival" do
      conn = build_conn()
      open_group!(conn, "g-late")
      submit!(conn, [payment_operation("g-late", 5000)])

      assert [result] = submit!(conn, [cancel_operation("g-late", "2026-11-27")])
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5000
      assert result["revision"] == 3

      assert ledger(conn)["cash_retained_cents"] == 5000
      assert ledger(conn)["cash_held_cents"] == 0
    end

    test "advance purchase reservations are never refundable" do
      conn = build_conn()

      open_group!(conn, "g-ap-cancel", fn operation ->
        %{operation | "rate_plan" => "advance_purchase"}
      end)

      submit!(conn, [payment_operation("g-ap-cancel", 97_500)])

      assert [result] = submit!(conn, [cancel_operation("g-ap-cancel", "2026-10-04")])
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 97_500
    end

    test "an unpaid group cancels with nothing refunded or retained" do
      conn = build_conn()
      open_group!(conn, "g-unpaid")

      assert [result] = submit!(conn, [cancel_operation("g-unpaid")])
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["revision"] == 2

      data = group_data(conn, "g-unpaid")
      assert data["status"] == "cancelled"
      assert data["outstanding_deposit_cents"] == 0
    end

    test "a cancelled group is no longer active" do
      conn = build_conn()
      open_group!(conn, "g-done")
      submit!(conn, [cancel_operation("g-done")])

      assert [pay, move, cancel] =
               submit!(conn, [
                 payment_operation("g-done", 100),
                 reschedule_operation("g-done", "2026-12-20"),
                 cancel_operation("g-done")
               ])

      assert pay["code"] == "group_not_active"
      assert move["code"] == "group_not_active"
      assert cancel["code"] == "group_not_active"
      assert group_data(conn, "g-done")["revision"] == 2
    end

    test "the refund window counts from the rescheduled arrival date" do
      conn = build_conn()
      open_group!(conn, "g-moved-cancel")
      submit!(conn, [payment_operation("g-moved-cancel", 5000)])

      # Moving closer to arrival pushes the group inside the 14-day window.
      submit!(conn, [reschedule_operation("g-moved-cancel", "2026-11-20")])

      assert [result] = submit!(conn, [cancel_operation("g-moved-cancel", "2026-11-10")])
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5000
      assert result["revision"] == 4
    end

    test "rejects a cancellation for a missing group with group_not_found" do
      conn = build_conn()

      assert [result] = submit!(conn, [cancel_operation("g-missing")])
      assert result["code"] == "group_not_found"
    end
  end

  describe "revisions" do
    test "open_group does not use expected_revision" do
      conn = build_conn()

      assert [result] =
               submit!(conn, [Map.put(open_operation("g-open-rev"), "expected_revision", 42)])

      assert result["status"] == "applied"
      assert result["revision"] == 1
    end

    test "a matching expected_revision applies" do
      conn = build_conn()
      open_group!(conn, "g-match")

      assert [result] = submit!(conn, [payment_operation("g-match", 100, 1)])
      assert result["status"] == "applied"
      assert result["revision"] == 2
    end

    test "a stale revision is rejected with the documented fields and no changes" do
      conn = build_conn()
      open_group!(conn, "g-stale")

      assert [result] = submit!(conn, [payment_operation("g-stale", 100, 7)])

      assert result == %{
               "operation_id" => "op-pay-g-stale-100",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "g-stale",
               "expected_revision" => 7,
               "actual_revision" => 1
             }

      data = group_data(conn, "g-stale")
      assert data["revision"] == 1
      assert data["deposit_paid_cents"] == 0
      assert ledger(conn)["cash_held_cents"] == 0
    end

    test "a stale revision sees changes made earlier in the same batch" do
      conn = build_conn()
      open_group!(conn, "g-batch-stale")

      assert [pay, stale] =
               submit!(conn, [
                 payment_operation("g-batch-stale", 100),
                 payment_operation("g-batch-stale", 100, 1)
               ])

      assert pay["status"] == "applied"
      assert pay["revision"] == 2
      assert stale["code"] == "stale_revision"
      assert stale["expected_revision"] == 1
      assert stale["actual_revision"] == 2
      assert group_data(conn, "g-batch-stale")["revision"] == 2
    end

    test "group existence is resolved before the revision comparison" do
      conn = build_conn()

      assert [result] = submit!(conn, [payment_operation("g-no-rev", 100, 1)])
      assert result["code"] == "group_not_found"
    end

    test "a stale revision is rejected before the operation's other domain rules" do
      conn = build_conn()
      open_group!(conn, "g-order")

      # The amount is unusable, but the stale revision is reported first.
      assert [result] =
               submit!(conn, [Map.put(payment_operation("g-order", 0, 99), "amount_cents", 0)])

      assert result["code"] == "stale_revision"

      # And on an inactive group, the stale revision still wins.
      submit!(conn, [payment_operation("g-order", 100)])
      submit!(conn, [cancel_operation("g-order", @occurred_on, 2)])

      assert [result] = submit!(conn, [cancel_operation("g-order", @occurred_on, 1)])
      assert result["code"] == "stale_revision"
    end

    test "every applied operation increments the revision exactly once" do
      conn = build_conn()
      open_group!(conn, "g-count")

      assert [pay] = submit!(conn, [payment_operation("g-count", 100)])
      assert pay["revision"] == 2

      assert [move] = submit!(conn, [reschedule_operation("g-count", "2026-12-12")])
      assert move["revision"] == 3

      assert [cancel] = submit!(conn, [cancel_operation("g-count")])
      assert cancel["revision"] == 4

      assert group_data(conn, "g-count")["revision"] == 4
    end
  end

  describe "invalid operations" do
    test "unknown operation types are rejected with invalid_operation" do
      conn = build_conn()

      assert [result] =
               submit!(conn, [
                 %{"operation_id" => "op-x", "type" => "explode", "occurred_on" => @occurred_on}
               ])

      assert result == %{
               "operation_id" => "op-x",
               "status" => "rejected",
               "code" => "invalid_operation"
             }
    end

    test "operations missing identifying data are rejected with invalid_operation" do
      conn = build_conn()
      open_group!(conn, "g-struct")

      malformed = [
        %{
          "occurred_on" => @occurred_on,
          "type" => "record_cash_payment",
          "group_id" => "g-struct",
          "amount_cents" => 1
        },
        %{
          "operation_id" => "op-x",
          "occurred_on" => @occurred_on,
          "group_id" => "g-struct",
          "amount_cents" => 1
        },
        %{
          "operation_id" => "op-x",
          "type" => "record_cash_payment",
          "group_id" => "g-struct",
          "amount_cents" => 1
        },
        %{
          "operation_id" => "op-x",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-13-45",
          "group_id" => "g-struct",
          "amount_cents" => 1
        },
        %{
          "operation_id" => "op-x",
          "type" => "record_cash_payment",
          "occurred_on" => @occurred_on,
          "amount_cents" => 1
        },
        %{
          "operation_id" => "op-x",
          "type" => "open_group",
          "occurred_on" => @occurred_on,
          "group_id" => "g-new",
          "arrival_on" => @arrival_on,
          "departure_on" => @departure_on,
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 100}]
        }
      ]

      for operation <- malformed do
        assert [result] = submit!(conn, [operation])
        assert result["code"] == "invalid_operation", inspect(operation)
      end

      assert [result] = submit!(conn, ["not-an-operation"])

      assert result == %{
               "operation_id" => nil,
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      # None of the rejected operations touched the group or the ledger.
      assert group_data(conn, "g-struct")["revision"] == 1
      assert ledger(conn)["cash_held_cents"] == 0
    end

    test "a non-integer expected_revision is rejected with invalid_operation" do
      conn = build_conn()
      open_group!(conn, "g-rev-type")

      assert [result] =
               submit!(conn, [
                 Map.put(payment_operation("g-rev-type", 100), "expected_revision", "1")
               ])

      assert result["code"] == "invalid_operation"
    end
  end

  describe "operations within one batch" do
    test "an operation observes changes made by an earlier operation" do
      conn = build_conn()

      assert [open, pay] =
               submit!(conn, [open_operation("g-seq"), payment_operation("g-seq", 5000)])

      assert open["status"] == "applied"
      assert pay["status"] == "applied"
      assert pay["revision"] == 2
      assert pay["outstanding_deposit_cents"] == 14_500
    end

    test "a group opened earlier in the batch already exists to a later open" do
      conn = build_conn()

      assert [first, second] =
               submit!(conn, [open_operation("g-twice"), open_operation("g-twice")])

      assert first["status"] == "applied"
      assert second["code"] == "group_already_exists"
      assert group_data(conn, "g-twice")["revision"] == 1
    end
  end
end
