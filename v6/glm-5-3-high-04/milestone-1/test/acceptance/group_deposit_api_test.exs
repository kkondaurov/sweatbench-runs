defmodule GroupStayWeb.GroupDepositAPITest do
  use GroupStayWeb.ConnCase, async: false

  @batch_url "/api/v1/partner-batches"

  defp post_batch(conn, operations) do
    post(conn, @batch_url, %{"operations" => operations})
  end

  defp open_group_operation(overrides \\ %{}) do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 9_500
      },
      overrides
    )
  end

  defp reschedule_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-15"
      },
      overrides
    )
  end

  defp cancel_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp apply_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    result
  end

  defp reject_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "rejected", "expected rejected, got: #{inspect(result)}"
    result
  end

  defp open_group!(conn, overrides \\ %{}) do
    apply_operation!(conn, open_group_operation(overrides))
  end

  defp fetch_group(conn, group_id) do
    conn = get(conn, "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp ledger(conn) do
    conn = get(conn, "/api/v1/ledger")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  describe "opening a group" do
    test "applies the operation from the API example", %{conn: conn} do
      op = open_group_operation(%{"operation_id" => "op-1001"})

      conn = post_batch(conn, [op])

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result == open_group_result(op, 19_500, 1)
    end

    test "stores the group readable through the read endpoint", %{conn: conn} do
      open_group!(conn)

      assert fetch_group(conn, "group-81") == %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
    end

    test "advance_purchase rooms owe their full lodging amount", %{conn: conn} do
      result =
        open_group!(conn, %{"rate_plan" => "advance_purchase", "group_id" => "group-ap"})

      assert result["deposit_due_cents"] == 97_500

      assert fetch_group(conn, "group-ap")["deposit_due_cents"] == 97_500
    end

    test "flexible deposits are calculated and rounded per room", %{conn: conn} do
      # Per-room: 30001 -> 6000, 30002 -> 6000 (group-level rounding would say 12001).
      result =
        open_group!(conn, %{
          "group_id" => "group-round",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 30_001},
            %{"room_id" => "room-b", "nightly_rate_cents" => 30_002}
          ]
        })

      assert result["deposit_due_cents"] == 12_000
      assert fetch_group(conn, "group-round")["lodging_total_cents"] == 60_003
    end

    test "flexible deposits round to the nearest cent", %{conn: conn} do
      # 10001 -> 2000.2 -> 2000, 10002 -> 2000.4 -> 2000, 10003 -> 2000.6 -> 2001.
      result =
        open_group!(conn, %{
          "group_id" => "group-round",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10_001},
            %{"room_id" => "room-b", "nightly_rate_cents" => 10_002},
            %{"room_id" => "room-c", "nightly_rate_cents" => 10_003}
          ]
        })

      assert result["deposit_due_cents"] == 6_001
    end

    test "rejects a duplicate group identifier and keeps the original group", %{conn: conn} do
      open_group!(conn)

      result =
        reject_operation!(conn, open_group_operation(%{"rate_plan" => "advance_purchase"}))

      assert result["code"] == "group_already_exists"

      group = fetch_group(conn, "group-81")
      assert group["rate_plan"] == "flexible"
      assert group["revision"] == 1
    end

    test "rejects unusable stays with invalid_stay", %{conn: conn} do
      for overrides <-
            [
              %{"departure_on" => "2026-12-10"},
              %{"departure_on" => "2026-12-09"},
              %{"arrival_on" => "not-a-date"},
              %{"departure_on" => "2026-13-45"},
              %{"arrival_on" => nil}
            ] do
        result = reject_operation!(conn, open_group_operation(overrides))
        assert result["code"] == "invalid_stay", "for #{inspect(overrides)}"
      end
    end

    test "rejects unusable rooms with invalid_rooms", %{conn: conn} do
      for overrides <-
            [
              %{"rooms" => []},
              %{"rooms" => nil},
              %{"rooms" => "room-a"},
              %{
                "rooms" => [
                  %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                  %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
                ]
              },
              %{"rooms" => [%{"nightly_rate_cents" => 15_000}]},
              %{"rooms" => [%{"room_id" => "room-a"}]},
              %{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -1}]},
              %{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}]}
            ] do
        result = reject_operation!(conn, open_group_operation(overrides))
        assert result["code"] == "invalid_rooms", "for #{inspect(overrides)}"
      end
    end

    test "rejects unknown rate plans with invalid_rate_plan", %{conn: conn} do
      for rate_plan <- ["promo", "", nil, "Flexible"] do
        result = reject_operation!(conn, open_group_operation(%{"rate_plan" => rate_plan}))
        assert result["code"] == "invalid_rate_plan", "for #{inspect(rate_plan)}"
      end
    end

    test "rejects operations missing identification data with invalid_operation", %{conn: conn} do
      for overrides <-
            [
              %{"group_id" => nil},
              %{"group_id" => ""},
              %{"guest_id" => nil},
              %{"property_id" => nil},
              %{"operation_id" => nil},
              %{"operation_id" => ""},
              %{"type" => nil},
              %{"type" => "noop"},
              %{"occurred_on" => nil},
              %{"occurred_on" => "yesterday"}
            ] do
        result = reject_operation!(conn, open_group_operation(overrides))
        assert result["code"] == "invalid_operation", "for #{inspect(overrides)}"
      end
    end
  end

  describe "recording cash" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      open_group!(conn)

      result =
        apply_operation!(conn, payment_operation(%{"operation_id" => "op-pay"}))

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 9_500,
               "outstanding_deposit_cents" => 10_000,
               "revision" => 2
             }

      group = fetch_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 9_500
      assert group["outstanding_deposit_cents"] == 10_000
      assert group["revision"] == 2
    end

    test "collects the deposit across several payments", %{conn: conn} do
      open_group!(conn)

      apply_operation!(conn, payment_operation(%{"amount_cents" => 9_500}))
      result = apply_operation!(conn, payment_operation(%{"amount_cents" => 10_000}))

      assert result["outstanding_deposit_cents"] == 0
      assert result["revision"] == 3

      assert ledger(conn)["cash_held_cents"] == 19_500
    end

    test "rejects payments exceeding the outstanding deposit without changes", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 9_500}))

      result = reject_operation!(conn, payment_operation(%{"amount_cents" => 10_001}))

      assert result["code"] == "payment_exceeds_outstanding"

      group = fetch_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 9_500
      assert group["revision"] == 2
      assert ledger(conn)["cash_held_cents"] == 9_500
    end

    test "rejects unusable amounts with invalid_amount", %{conn: conn} do
      open_group!(conn)

      for amount <- [0, -100, "500", 1.5, nil] do
        result = reject_operation!(conn, payment_operation(%{"amount_cents" => amount}))
        assert result["code"] == "invalid_amount", "for #{inspect(amount)}"
      end
    end

    test "rejects payments to missing groups with group_not_found", %{conn: conn} do
      result = reject_operation!(conn, payment_operation(%{"group_id" => "group-missing"}))

      assert result["code"] == "group_not_found"
    end

    test "rejects payments without a group identifier with invalid_operation", %{conn: conn} do
      result = reject_operation!(conn, payment_operation(%{"group_id" => nil}))

      assert result["code"] == "invalid_operation"
    end
  end

  describe "rescheduling" do
    test "moves the stay by the same number of days", %{conn: conn} do
      open_group!(conn)

      result = apply_operation!(conn, reschedule_operation(%{"new_arrival_on" => "2026-12-15"}))

      assert result == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-15",
               "new_departure_on" => "2026-12-18",
               "revision" => 2
             }

      group = fetch_group(conn, "group-81")
      assert group["arrival_on"] == "2026-12-15"
      assert group["departure_on"] == "2026-12-18"
      assert group["booked_on"] == "2026-10-03"
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
      assert group["revision"] == 2
    end

    test "rejects unusable new arrival dates with invalid_stay", %{conn: conn} do
      open_group!(conn)

      for new_arrival <- ["2026-10-04", "2026-09-30", "soon", nil] do
        result = reject_operation!(conn, reschedule_operation(%{"new_arrival_on" => new_arrival}))
        assert result["code"] == "invalid_stay", "for #{inspect(new_arrival)}"
      end
    end

    test "rejects reschedules of missing groups with group_not_found", %{conn: conn} do
      result = reject_operation!(conn, reschedule_operation(%{"group_id" => "group-missing"}))

      assert result["code"] == "group_not_found"
    end
  end

  describe "cancelling a group" do
    test "refunds flexible reservations cancelled at least 14 days before arrival", %{
      conn: conn
    } do
      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 9_500}))

      result =
        apply_operation!(conn, cancel_operation(%{"occurred_on" => "2026-11-26"}))

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 9_500,
               "retained_cents" => 0,
               "revision" => 3
             }

      group = fetch_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 9_500,
               "cash_retained_cents" => 0
             }
    end

    test "retains cash from flexible reservations cancelled less than 14 days before arrival",
         %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 9_500}))

      result =
        apply_operation!(conn, cancel_operation(%{"occurred_on" => "2026-11-27"}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 9_500

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 9_500
             }
    end

    test "retains cash from advance_purchase reservations regardless of timing", %{conn: conn} do
      open_group!(conn, %{
        "group_id" => "group-ap",
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      })

      apply_operation!(
        conn,
        payment_operation(%{"group_id" => "group-ap", "amount_cents" => 20_000})
      )

      result = apply_operation!(conn, cancel_operation(%{"group_id" => "group-ap"}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 20_000
    end

    test "cancelling an unpaid group settles nothing and clears the outstanding deposit", %{
      conn: conn
    } do
      open_group!(conn)

      result = apply_operation!(conn, cancel_operation())

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      group = fetch_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "rejects later operations on a cancelled group with group_not_active", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, cancel_operation())

      for operation <- [
            payment_operation(%{"amount_cents" => 100}),
            reschedule_operation(),
            cancel_operation()
          ] do
        result = reject_operation!(conn, operation)
        assert result["code"] == "group_not_active", "for #{inspect(operation["type"])}"
      end

      assert fetch_group(conn, "group-81")["revision"] == 2
    end

    test "rejects cancellations of missing groups with group_not_found", %{conn: conn} do
      result = reject_operation!(conn, cancel_operation(%{"group_id" => "group-missing"}))

      assert result["code"] == "group_not_found"
    end
  end

  describe "revisions" do
    test "increments once per applied operation", %{conn: conn} do
      open_group!(conn)

      assert apply_operation!(conn, payment_operation())["revision"] == 2

      assert apply_operation!(
               conn,
               reschedule_operation(%{"new_arrival_on" => "2026-12-20"})
             )["revision"] == 3

      assert apply_operation!(conn, cancel_operation())["revision"] == 4
    end

    test "rejects a stale revision before other domain rules and changes nothing", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation())

      conn = post_batch(conn, [payment_operation(%{"expected_revision" => 1})])

      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      group = fetch_group(conn, "group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 9_500

      assert ledger(conn)["cash_held_cents"] == 9_500
    end

    test "applies operations carrying the current revision", %{conn: conn} do
      open_group!(conn)

      result =
        apply_operation!(conn, payment_operation(%{"expected_revision" => 1}))

      assert result["revision"] == 2
    end

    test "sees changes made by earlier operations in the same batch", %{conn: conn} do
      conn
      |> post_batch([
        open_group_operation(),
        payment_operation(%{"operation_id" => "op-pay-1"}),
        payment_operation(%{"operation_id" => "op-pay-2", "expected_revision" => 1}),
        payment_operation(%{"operation_id" => "op-pay-3", "expected_revision" => 2})
      ])
      |> json_response(200)
      |> then(fn %{"results" => results} ->
        assert Enum.at(results, 0)["status"] == "applied"
        assert Enum.at(results, 1)["revision"] == 2

        assert Enum.at(results, 2) == %{
                 "operation_id" => "op-pay-2",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }

        assert Enum.at(results, 3)["revision"] == 3
      end)

      assert fetch_group(conn, "group-81")["revision"] == 3
    end

    test "ignores expected_revision when opening a group", %{conn: conn} do
      result = open_group!(conn, %{"expected_revision" => 99})

      assert result["revision"] == 1
    end

    test "resolves group existence before comparing revisions", %{conn: conn} do
      result =
        reject_operation!(
          conn,
          payment_operation(%{"group_id" => "group-missing", "expected_revision" => 4})
        )

      assert result["code"] == "group_not_found"
    end

    test "rejects the stale revision of an inactive group before group_not_active", %{
      conn: conn
    } do
      open_group!(conn)
      apply_operation!(conn, payment_operation())
      apply_operation!(conn, cancel_operation())

      result =
        reject_operation!(
          conn,
          payment_operation(%{"expected_revision" => 1, "amount_cents" => 0})
        )

      assert result["code"] == "stale_revision"
    end
  end

  describe "batches" do
    test "returns one result per operation in order and keeps processing after rejections", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_operation(%{"operation_id" => "op-1"}),
          payment_operation(%{"operation_id" => "op-2", "group_id" => "group-missing"}),
          payment_operation(%{"operation_id" => "op-3", "amount_cents" => 9_500}),
          open_group_operation(%{"operation_id" => "op-4", "group_id" => "group-82"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert length(results) == 4
      assert Enum.map(results, & &1["operation_id"]) == ["op-1", "op-2", "op-3", "op-4"]
      assert Enum.map(results, & &1["status"]) == ["applied", "rejected", "applied", "applied"]
      assert Enum.at(results, 1)["code"] == "group_not_found"
      assert Enum.at(results, 2)["revision"] == 2
    end

    test "rejects operations that are not maps with invalid_operation", %{conn: conn} do
      conn = post_batch(conn, ["nope"])

      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => nil,
               "status" => "rejected",
               "code" => "invalid_operation"
             }
    end

    test "rejects a batch without an operations array with 422 invalid_batch", %{conn: conn} do
      conn = post(conn, @batch_url, %{})
      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)

      conn = post(conn, @batch_url, %{"operations" => "all of them"})
      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)

      conn = post(conn, @batch_url)
      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "accepts an empty operations array", %{conn: conn} do
      conn = post_batch(conn, [])

      assert %{"results" => []} = json_response(conn, 200)
    end
  end

  describe "reads" do
    test "returns 404 for a missing group", %{conn: conn} do
      conn = get(conn, "/api/v1/groups/group-missing")

      assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
    end

    test "ledger starts empty", %{conn: conn} do
      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "ledger aggregates cash across groups", %{conn: conn} do
      # Active group holding cash.
      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 5_000}))

      # Refundable flexible cancellation.
      open_group!(conn, %{
        "group_id" => "group-ref",
        "arrival_on" => "2026-12-01"
      })

      apply_operation!(
        conn,
        payment_operation(%{"group_id" => "group-ref", "amount_cents" => 3_000})
      )

      apply_operation!(conn, cancel_operation(%{"group_id" => "group-ref"}))

      # Advance-purchase cancellation.
      open_group!(conn, %{
        "group_id" => "group-ap",
        "rate_plan" => "advance_purchase"
      })

      apply_operation!(
        conn,
        payment_operation(%{"group_id" => "group-ap", "amount_cents" => 2_000})
      )

      apply_operation!(conn, cancel_operation(%{"group_id" => "group-ap"}))

      assert ledger(conn) == %{
               "cash_held_cents" => 5_000,
               "cash_refunded_cents" => 3_000,
               "cash_retained_cents" => 2_000
             }
    end
  end

  defp open_group_result(operation, deposit_due_cents, revision) do
    %{
      "operation_id" => operation["operation_id"],
      "status" => "applied",
      "group_id" => operation["group_id"],
      "deposit_due_cents" => deposit_due_cents,
      "revision" => revision
    }
  end
end
