defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "opens a group and returns all group fields", %{conn: conn} do
      operation =
        open_operation(%{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10_001},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
        })

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => [operation]})

      assert %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-1",
                   "deposit_due_cents" => 16_501,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert %{
               "data" => %{
                 "group_id" => "group-1",
                 "guest_id" => "guest-1",
                 "property_id" => "ams-canal",
                 "revision" => 1,
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 10_001},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ],
                 "lodging_total_cents" => 82_503,
                 "deposit_due_cents" => 16_501,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 16_501
               }
             } = json_response(conn, 200)
    end

    test "applies payment and reschedule operations in batch order", %{conn: conn} do
      operations = [
        open_operation(),
        %{
          "operation_id" => "pay-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-1",
          "amount_cents" => 5_000,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "move-1",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-1",
          "new_arrival_on" => "2026-12-20",
          "expected_revision" => 2
        }
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [_, payment, move]} = json_response(conn, 200)

      assert payment == %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 4_000,
               "revision" => 2
             }

      assert move == %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "group-1",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 3
             }
    end

    test "settles refundable and retained cash in the ledger", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation("pay-1", "group-1", 9_000),
        cancellation_operation("cancel-1", "group-1", "2026-11-26"),
        open_operation(%{
          "operation_id" => "open-2",
          "group_id" => "group-2",
          "rate_plan" => "advance_purchase"
        }),
        payment_operation("pay-2", "group-2", 45_000),
        cancellation_operation("cancel-2", "group-2", "2026-10-04")
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
      assert %{"results" => [_, _, flexible, _, _, advance]} = json_response(conn, 200)

      assert flexible["refunded_cents"] == 9_000
      assert flexible["retained_cents"] == 0
      assert advance["refunded_cents"] == 0
      assert advance["retained_cents"] == 45_000

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 9_000,
                 "cash_retained_cents" => 45_000,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }
    end

    test "checks revision before domain validation and never increments on rejection", %{
      conn: conn
    } do
      operations = [
        open_operation(),
        Map.put(payment_operation("stale", "group-1", -1), "expected_revision", 9),
        Map.put(payment_operation("valid", "group-1", 1_000), "expected_revision", 1),
        Map.put(payment_operation("stale-after", "group-1", 1_000), "expected_revision", 1)
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
      assert %{"results" => [_, stale, valid, stale_after]} = json_response(conn, 200)

      assert stale == %{
               "operation_id" => "stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-1",
               "expected_revision" => 9,
               "actual_revision" => 1
             }

      assert valid["revision"] == 2
      assert stale_after["code"] == "stale_revision"
      assert stale_after["actual_revision"] == 2
    end

    test "rejects invalid operations atomically and continues processing", %{conn: conn} do
      invalid_open =
        open_operation(%{
          "operation_id" => "bad-open",
          "group_id" => "bad-group",
          "rooms" => [
            %{"room_id" => "duplicate", "nightly_rate_cents" => 1_000},
            %{"room_id" => "duplicate", "nightly_rate_cents" => 2_000}
          ]
        })

      conn =
        post(conn, "/api/v1/partner-batches", %{
          "operations" => [
            invalid_open,
            open_operation(),
            %{"operation_id" => "unknown", "type" => "other"}
          ]
        })

      assert %{"results" => [bad, good, unknown]} = json_response(conn, 200)
      assert bad["code"] == "invalid_rooms"
      assert good["status"] == "applied"

      assert unknown == %{
               "operation_id" => "unknown",
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert json_response(get(build_conn(), "/api/v1/groups/bad-group"), 404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end

    test "rejects malformed payment dates and oversized room totals without stopping", %{
      conn: conn
    } do
      oversized =
        open_operation(%{
          "operation_id" => "oversized",
          "group_id" => "oversized-group",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 9_223_372_036_854_775_807}
          ]
        })

      invalid_payment = Map.delete(payment_operation("bad-date", "group-1", 100), "occurred_on")

      malformed_payment =
        payment_operation("malformed-date", "group-1", 100)
        |> Map.put("occurred_on", "not-a-date")

      conn =
        post(conn, "/api/v1/partner-batches", %{
          "operations" => [
            open_operation(),
            invalid_payment,
            malformed_payment,
            oversized,
            payment_operation("valid", "group-1", 100)
          ]
        })

      assert %{"results" => [_, bad_date, malformed_date, bad_rooms, valid]} =
               json_response(conn, 200)

      assert bad_date["code"] == "invalid_operation"
      assert malformed_date["code"] == "invalid_operation"
      assert bad_rooms["code"] == "invalid_rooms"
      assert valid["status"] == "applied"
      assert valid["revision"] == 2
    end

    test "returns stable domain validation errors", %{conn: conn} do
      operations = [
        open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
        open_operation(%{"operation_id" => "bad-rate", "rate_plan" => "weekend"}),
        open_operation(),
        payment_operation("bad-amount", "group-1", 0),
        payment_operation("too-much", "group-1", 9_001),
        payment_operation("missing", "missing-group", 100),
        %{
          "operation_id" => "bad-move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-1",
          "new_arrival_on" => "2026-10-05"
        }
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_stay",
               "invalid_rate_plan",
               nil,
               "invalid_amount",
               "payment_exceeds_outstanding",
               "group_not_found",
               "invalid_stay"
             ]
    end

    test "rejects a missing or non-array operations value", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_batch"}} =
               conn
               |> post("/api/v1/partner-batches", %{})
               |> json_response(422)

      assert %{"error" => %{"code" => "invalid_batch"}} =
               build_conn()
               |> post("/api/v1/partner-batches", %{"operations" => %{}})
               |> json_response(422)
    end
  end

  test "GET /api/v1/ledger starts at zero", %{conn: conn} do
    assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      },
      overrides
    )
  end

  defp payment_operation(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancellation_operation(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end
end
