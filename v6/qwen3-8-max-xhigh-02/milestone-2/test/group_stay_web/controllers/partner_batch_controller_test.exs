defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  @open_group %{
    "operation_id" => "op-1001",
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
  }

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp results(conn) do
    json_response(conn, 200)["results"]
  end

  defp single_result(conn, operations) do
    [result] = conn |> submit(operations) |> results()
    result
  end

  defp open_group(conn, overrides \\ %{}) do
    op = Map.merge(@open_group, overrides)
    result = single_result(conn, [op])
    assert result["status"] == "applied"
    result
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  defp reschedule_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-12"
      },
      overrides
    )
  end

  defp cancel_op(overrides \\ %{}) do
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

  defp get_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  describe "open_group" do
    test "opens the group from the API example and prices it", %{conn: conn} do
      result = single_result(conn, [@open_group])

      assert result == %{
               "operation_id" => "op-1001",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
               "revision" => 1
             }

      group = get_group(conn, "group-81")

      assert group == %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
               ],
               "lodging_total_cents" => 97500,
               "deposit_due_cents" => 19500,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19500
             }
    end

    test "the operation date becomes the booked_on date", %{conn: conn} do
      open_group(conn, %{"operation_id" => "op-9", "occurred_on" => "2026-11-01"})
      assert get_group(conn, "group-81")["booked_on"] == "2026-11-01"
    end

    test "an advance_purchase group deposits the full lodging amount", %{conn: conn} do
      result = open_group(conn, %{"rate_plan" => "advance_purchase"})
      assert result["deposit_due_cents"] == 97500
      assert get_group(conn, "group-81")["deposit_due_cents"] == 97500
    end

    test "flexible deposits round each room separately, then sum", %{conn: conn} do
      # One night each at 10002: each room's deposit is 2000.4, rounding to
      # 2000, so the group total is 4000. Rounding 20% of the combined
      # lodging (4000.8) instead would wrongly give 4001.
      result =
        open_group(conn, %{
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10002},
            %{"room_id" => "room-b", "nightly_rate_cents" => 10002}
          ]
        })

      assert result["deposit_due_cents"] == 4000
    end

    test "flexible deposits round to the nearest cent", %{conn: conn} do
      # One night each: 10005 -> exactly 2001.0; 10001 -> 2000.2 (down to
      # 2000); 10004 -> 2000.8 (up to 2001).
      result =
        open_group(conn, %{
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10005},
            %{"room_id" => "room-b", "nightly_rate_cents" => 10001},
            %{"room_id" => "room-c", "nightly_rate_cents" => 10004}
          ]
        })

      assert result["deposit_due_cents"] == 2001 + 2000 + 2001
    end

    test "rejects a duplicate group without touching the existing one", %{conn: conn} do
      open_group(conn)

      result =
        single_result(conn, [Map.put(@open_group, "operation_id", "op-dup")])

      assert result == %{
               "operation_id" => "op-dup",
               "status" => "rejected",
               "code" => "group_already_exists"
             }

      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "rejects a stay without at least one night", %{conn: conn} do
      for overrides <- [
            %{"departure_on" => "2026-12-10"},
            %{"departure_on" => "2026-12-09"}
          ] do
        result = single_result(conn, [Map.merge(@open_group, overrides)])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end

      assert conn |> get("/api/v1/groups/group-81") |> json_response(404) ==
               %{"error" => %{"code" => "group_not_found"}}
    end

    test "rejects rooms that cannot be used", %{conn: conn} do
      batches = [
        [%{@open_group | "rooms" => []}],
        [
          %{
            @open_group
            | "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                %{"room_id" => "room-a", "nightly_rate_cents" => 16000}
              ]
          }
        ],
        [%{@open_group | "rooms" => [%{"nightly_rate_cents" => 15000}]}],
        [%{@open_group | "rooms" => [%{"room_id" => "room-a"}]}],
        [%{@open_group | "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 0}]}],
        [%{@open_group | "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -100}]}]
      ]

      for batch <- batches do
        [result] = results(submit(conn, batch))
        assert result["status"] == "rejected", "expected rejection for #{inspect(batch)}"
        assert result["code"] == "invalid_rooms", "expected invalid_rooms for #{inspect(batch)}"
      end
    end

    test "rejects an unknown rate plan", %{conn: conn} do
      result = single_result(conn, [%{@open_group | "rate_plan" => "nonrefundable"}])
      assert result["status"] == "rejected"
      assert result["code"] == "invalid_rate_plan"
    end

    test "rejects operations missing data needed to apply them", %{conn: conn} do
      missing_field_batches =
        for key <-
              ~w(group_id guest_id property_id occurred_on arrival_on departure_on rate_plan rooms) do
          [Map.delete(@open_group, key)]
        end

      malformed_batches = [
        [%{@open_group | "arrival_on" => "not-a-date"}],
        [%{@open_group | "rooms" => "room-a"}],
        [%{@open_group | "group_id" => ""}]
      ]

      for batch <- missing_field_batches ++ malformed_batches do
        [result] = results(submit(conn, batch))
        assert result["status"] == "rejected", "expected rejection for #{inspect(batch)}"

        assert result["code"] == "invalid_operation",
               "expected invalid_operation for #{inspect(batch)}"
      end

      assert conn |> get("/api/v1/groups/group-81") |> json_response(404)
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      open_group(conn)

      result = single_result(conn, [payment_op()])

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14500,
               "revision" => 2
             }

      group = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 5000
      assert group["outstanding_deposit_cents"] == 14500

      result =
        single_result(conn, [payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 14500})])

      assert result["outstanding_deposit_cents"] == 0
      assert result["revision"] == 3
    end

    test "rejects a payment for a missing group", %{conn: conn} do
      result = single_result(conn, [payment_op(%{"group_id" => "nope"})])

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "group_not_found"
             }
    end

    test "rejects unusable amounts without changing the group", %{conn: conn} do
      open_group(conn)

      for amount <- [0, -500, "5000", 10.5, nil] do
        op =
          if amount == nil do
            Map.delete(payment_op(), "amount_cents")
          else
            payment_op(%{"amount_cents" => amount})
          end

        [result] = results(submit(conn, [op]))
        assert result["status"] == "rejected", "expected rejection for #{inspect(amount)}"

        expected_code = if amount == nil, do: "invalid_operation", else: "invalid_amount"
        assert result["code"] == expected_code, "unexpected code for #{inspect(amount)}"
      end

      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "rejects a payment exceeding the outstanding deposit", %{conn: conn} do
      open_group(conn)

      result = single_result(conn, [payment_op(%{"amount_cents" => 19501})])
      assert result["status"] == "rejected"
      assert result["code"] == "payment_exceeds_outstanding"

      # Paying exactly the outstanding amount is fine.
      result = single_result(conn, [payment_op(%{"amount_cents" => 19500})])
      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 0

      # Once fully paid, any further payment exceeds the outstanding deposit.
      result = single_result(conn, [payment_op(%{"amount_cents" => 1})])
      assert result["status"] == "rejected"
      assert result["code"] == "payment_exceeds_outstanding"
    end

    test "rejects a payment for a cancelled group", %{conn: conn} do
      open_group(conn)
      assert single_result(conn, [cancel_op()])["status"] == "applied"

      result = single_result(conn, [payment_op()])
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"
    end

    test "rejects a payment missing its identifying data", %{conn: conn} do
      open_group(conn)

      for batch <- [
            [Map.delete(payment_op(), "group_id")],
            [Map.delete(payment_op(), "occurred_on")]
          ] do
        [result] = results(submit(conn, batch))
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end
    end
  end

  describe "reschedule_group" do
    test "shifts arrival and departure by the same number of days", %{conn: conn} do
      open_group(conn)

      result = single_result(conn, [reschedule_op()])

      assert result == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-12",
               "new_departure_on" => "2026-12-15",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-28",
               "revision" => 2
             }

      group = get_group(conn, "group-81")
      assert group["arrival_on"] == "2026-12-12"
      assert group["departure_on"] == "2026-12-15"
      # Length and price are unchanged.
      assert group["lodging_total_cents"] == 97500
      assert group["deposit_due_cents"] == 19500
    end

    test "applying it again without date changes still increments the revision", %{conn: conn} do
      open_group(conn)
      assert single_result(conn, [reschedule_op()])["revision"] == 2

      result =
        single_result(conn, [
          reschedule_op(%{"operation_id" => "op-move-2", "new_arrival_on" => "2026-12-12"})
        ])

      assert result["status"] == "applied"
      assert result["revision"] == 3
    end

    test "rejects a new arrival that is not after the operation date", %{conn: conn} do
      open_group(conn)

      for arrival <- ["2026-10-04", "2026-10-03", "2026-09-01"] do
        result = single_result(conn, [reschedule_op(%{"new_arrival_on" => arrival})])
        assert result["status"] == "rejected", "expected rejection for #{arrival}"
        assert result["code"] == "invalid_stay"
      end

      assert get_group(conn, "group-81")["arrival_on"] == "2026-12-10"
      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "rejects rescheduling a missing or cancelled group", %{conn: conn} do
      result = single_result(conn, [reschedule_op(%{"group_id" => "nope"})])
      assert result["code"] == "group_not_found"

      open_group(conn)
      assert single_result(conn, [cancel_op()])["status"] == "applied"

      result = single_result(conn, [reschedule_op()])
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"
    end

    test "rejects a reschedule with unusable data", %{conn: conn} do
      open_group(conn)

      for batch <- [
            [Map.delete(reschedule_op(), "new_arrival_on")],
            [reschedule_op(%{"new_arrival_on" => "soon"})]
          ] do
        [result] = results(submit(conn, batch))
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end
    end
  end

  describe "cancel_group" do
    test "refunds a flexible group cancelled at least 14 days before arrival", %{conn: conn} do
      open_group(conn)
      assert single_result(conn, [payment_op()])["status"] == "applied"

      # Arrival 2026-12-10; cancelling on 2026-11-26 is exactly 14 days out.
      result = single_result(conn, [cancel_op(%{"occurred_on" => "2026-11-26"})])

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 5000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      group = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0

      assert conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data") ==
               %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 5000,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
    end

    test "retains cash for a flexible group cancelled inside the window", %{conn: conn} do
      open_group(conn)
      assert single_result(conn, [payment_op()])["status"] == "applied"

      # 13 days before arrival: non-refundable.
      result = single_result(conn, [cancel_op(%{"occurred_on" => "2026-11-27"})])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5000

      assert conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data") ==
               %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 5000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
    end

    test "advance-purchase cancellations are never refundable", %{conn: conn} do
      open_group(conn, %{"rate_plan" => "advance_purchase"})
      assert single_result(conn, [payment_op()])["status"] == "applied"

      result = single_result(conn, [cancel_op(%{"occurred_on" => "2026-10-04"})])
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5000
    end

    test "unpaid deposit is simply no longer due", %{conn: conn} do
      open_group(conn)
      result = single_result(conn, [cancel_op()])
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      group = get_group(conn, "group-81")
      assert group["deposit_due_cents"] == 19500
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0

      assert conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data") ==
               %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
    end

    test "a cancelled group rejects later operations", %{conn: conn} do
      open_group(conn)
      assert single_result(conn, [cancel_op()])["status"] == "applied"

      for op <- [
            payment_op(),
            reschedule_op(),
            cancel_op(%{"operation_id" => "op-cancel-2"})
          ] do
        result = single_result(conn, [op])
        assert result["status"] == "rejected", "expected rejection for #{op["type"]}"
        assert result["code"] == "group_not_active"
      end

      assert get_group(conn, "group-81")["revision"] == 2
    end

    test "rejects cancelling a missing group", %{conn: conn} do
      result = single_result(conn, [cancel_op(%{"group_id" => "nope"})])
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"
    end
  end

  describe "expected_revision" do
    test "applies when it matches and rejects a stale revision with the documented fields", %{
      conn: conn
    } do
      open_group(conn)

      result = single_result(conn, [payment_op(%{"expected_revision" => 1})])
      assert result["status"] == "applied"
      assert result["revision"] == 2

      result = single_result(conn, [payment_op(%{"expected_revision" => 1})])

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      # The stale rejection left the group and ledger unchanged.
      group = get_group(conn, "group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 5000

      result = single_result(conn, [payment_op(%{"expected_revision" => 2})])
      assert result["status"] == "applied"
      assert result["revision"] == 3
    end

    test "group existence is resolved before comparing revisions", %{conn: conn} do
      result =
        single_result(conn, [payment_op(%{"group_id" => "nope", "expected_revision" => 1})])

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"
    end

    test "a stale revision is rejected before other domain rules", %{conn: conn} do
      open_group(conn)

      # The amount is unusable, but the stale revision wins.
      result =
        single_result(conn, [payment_op(%{"amount_cents" => 0, "expected_revision" => 99})])

      assert result["status"] == "rejected"
      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 1
    end

    test "rejections never increment the revision", %{conn: conn} do
      open_group(conn)

      for op <- [
            payment_op(%{"amount_cents" => 0}),
            payment_op(%{"amount_cents" => 99999}),
            reschedule_op(%{"new_arrival_on" => "2026-10-01"}),
            payment_op(%{"expected_revision" => 5})
          ] do
        assert single_result(conn, [op])["status"] == "rejected"
        assert get_group(conn, "group-81")["revision"] == 1
      end
    end

    test "omitting expected_revision keeps unconditional behavior", %{conn: conn} do
      open_group(conn)
      assert single_result(conn, [payment_op()])["status"] == "applied"

      assert single_result(conn, [payment_op(%{"operation_id" => "op-pay-2"})])["status"] ==
               "applied"
    end

    test "expected_revision is not used by open_group", %{conn: conn} do
      result = single_result(conn, [Map.put(@open_group, "expected_revision", 42)])
      assert result["status"] == "applied"
      assert result["revision"] == 1
    end
  end

  describe "batch processing" do
    test "processes operations in order and later operations see earlier changes", %{conn: conn} do
      results =
        conn
        |> submit([
          @open_group,
          payment_op(),
          reschedule_op(),
          cancel_op(%{"occurred_on" => "2026-11-26"})
        ])
        |> results()

      assert Enum.map(results, & &1["status"]) == ~w(applied applied applied applied)
      assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4]
      assert List.last(results)["refunded_cents"] == 5000
    end

    test "a rejected operation does not undo earlier ones or stop later ones", %{conn: conn} do
      results =
        conn
        |> submit([
          @open_group,
          payment_op(%{"amount_cents" => 0}),
          payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1000})
        ])
        |> results()

      assert Enum.map(results, & &1["status"]) == ~w(applied rejected applied)
      assert Enum.at(results, 1)["code"] == "invalid_amount"
      assert get_group(conn, "group-81")["deposit_paid_cents"] == 1000
    end

    test "returns one result per operation, in order", %{conn: conn} do
      results =
        conn
        |> submit([
          @open_group,
          Map.put(@open_group, "operation_id", "op-dup"),
          %{
            "operation_id" => "op-mystery",
            "type" => "extend_stay",
            "occurred_on" => "2026-10-03"
          }
        ])
        |> results()

      assert Enum.map(results, & &1["operation_id"]) == ["op-1001", "op-dup", "op-mystery"]
      assert Enum.map(results, & &1["status"]) == ~w(applied rejected rejected)
      assert Enum.at(results, 1)["code"] == "group_already_exists"
      assert Enum.at(results, 2)["code"] == "invalid_operation"
    end

    test "rejects unknown operation types and operations without identifying data", %{conn: conn} do
      batches = [
        [%{"operation_id" => "op-x", "type" => "renovate_group", "occurred_on" => "2026-10-03"}],
        [%{"operation_id" => "op-x", "occurred_on" => "2026-10-03"}],
        [%{"type" => "cancel_group", "occurred_on" => "2026-10-03", "group_id" => "group-81"}],
        ["junk"],
        [42]
      ]

      for batch <- batches do
        [result] = results(submit(conn, batch))
        assert result["status"] == "rejected", "expected rejection for #{inspect(batch)}"
        assert result["code"] == "invalid_operation"
      end
    end

    test "an empty operations list is a valid batch", %{conn: conn} do
      assert results(submit(conn, [])) == []
    end

    test "a body without an operations array is an invalid batch", %{conn: conn} do
      for body <- [%{}, %{"operations" => "nope"}, %{"operations" => %{"a" => 1}}] do
        conn =
          conn
          |> put_req_header("content-type", "application/json")
          |> post("/api/v1/partner-batches", Jason.encode!(body))

        assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
      end
    end
  end
end
