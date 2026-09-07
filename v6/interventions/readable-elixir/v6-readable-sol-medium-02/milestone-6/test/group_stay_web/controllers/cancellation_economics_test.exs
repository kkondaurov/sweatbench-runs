defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  describe "versioned cancellation policy" do
    test "fixes the policy at booking and recomputes its deadline when rescheduled", %{conn: conn} do
      opening =
        open_operation("modern", %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-04-15",
          "departure_on" => "2027-04-17"
        })

      move = %{
        "operation_id" => "move-modern",
        "type" => "reschedule_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "modern",
        "new_arrival_on" => "2027-06-01",
        "expected_revision" => 1
      }

      assert %{"results" => [_, result]} = submit(conn, [opening, move])
      assert result["policy_version"] == "flex-30"
      assert result["refundable_until"] == "2027-05-02"

      assert %{
               "data" => %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-05-02"
               }
             } = get_json("/api/v1/groups/modern")

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } =
               submit_then_get(
                 open_operation("advance", %{"rate_plan" => "advance_purchase"}),
                 "/api/v1/groups/advance"
               )
    end

    test "uses the inclusive 30-day boundary for new flexible groups", %{conn: conn} do
      opening =
        open_operation("modern", %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-17"
        })

      payment = payment_operation("modern", "pay-modern", 1_000)

      cancellation = %{
        "operation_id" => "cancel-modern",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-13",
        "group_id" => "modern"
      }

      assert %{"results" => [_, _, result]} = submit(conn, [opening, payment, cancellation])
      assert result["refunded_cents"] == 1_000
      assert result["retained_cents"] == 0
    end
  end

  describe "hotel credit" do
    test "converts refundable cash, applies credit, and restores its original lot", %{conn: conn} do
      issue_credit(conn, "source", "cancel-source", 1_000, "2027-02-01")

      assert %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 1_100,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-source",
                     "remaining_cents" => 1_100,
                     "expires_on" => "2028-02-01"
                   }
                 ]
               }
             } = get_json("/api/v1/guests/guest-22/credit?on=2027-02-01")

      destination =
        open_operation("destination", %{
          "operation_id" => "open-destination",
          "occurred_on" => "2027-02-02",
          "arrival_on" => "2027-05-01",
          "departure_on" => "2027-05-03"
        })

      apply_credit = credit_operation("destination", "credit-destination", 500, 1)

      assert %{"results" => [_, applied]} = submit(build_conn(), [destination, apply_credit])
      assert applied["outstanding_deposit_cents"] == 9_500
      assert applied["revision"] == 2

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 500
               }
             } = get_json("/api/v1/groups/destination")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 1_000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "credit_liability_cents" => 1_100
               }
             } = get_json("/api/v1/ledger?on=2027-03-01")

      cancel_destination = %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2027-03-01",
        "group_id" => "destination",
        "expected_revision" => 2
      }

      assert %{"results" => [result]} = submit(build_conn(), [cancel_destination])
      assert result["credit_issued_cents"] == 0
      assert result["refunded_cents"] == 0

      assert get_json("/api/v1/guests/guest-22/credit?on=2027-03-01")["data"]["available_cents"] ==
               1_100
    end

    test "does not revive an applied lot after its original expiry", %{conn: conn} do
      issue_credit(conn, "source", "cancel-source", 1_000, "2027-02-01")

      destination =
        open_operation("destination", %{
          "operation_id" => "open-destination",
          "occurred_on" => "2027-02-02",
          "arrival_on" => "2028-04-01",
          "departure_on" => "2028-04-03"
        })

      assert %{"results" => [_, %{"status" => "applied"}]} =
               submit(build_conn(), [
                 destination,
                 credit_operation("destination", "credit-destination", 1_100, 1)
               ])

      cancellation = %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2028-02-02",
        "group_id" => "destination"
      }

      assert %{"results" => [%{"status" => "applied"}]} = submit(build_conn(), [cancellation])

      assert get_json("/api/v1/guests/guest-22/credit?on=2028-02-02")["data"]["available_cents"] ==
               0

      assert get_json("/api/v1/ledger?on=2028-02-02")["data"]["credit_liability_cents"] == 0
    end

    test "rejects unavailable credit and hotel credit for non-refundable settlement", %{
      conn: conn
    } do
      advance = open_operation("advance", %{"rate_plan" => "advance_purchase"})

      insufficient = credit_operation("advance", "no-credit", 100, 1)

      invalid_refund = %{
        "operation_id" => "cancel-advance",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "advance",
        "refund_method" => "hotel_credit",
        "expected_revision" => 1
      }

      assert %{"results" => [_, no_credit, rejected]} =
               submit(conn, [advance, insufficient, invalid_refund])

      assert no_credit["code"] == "insufficient_credit"
      assert rejected["code"] == "refund_method_not_available"

      assert %{"data" => %{"status" => "active", "revision" => 1}} =
               get_json("/api/v1/groups/advance")
    end

    test "consumes applied credit on a non-refundable cancellation", %{conn: conn} do
      issue_credit(conn, "source", "cancel-source", 1_000, "2027-02-01")

      advance =
        open_operation("advance", %{
          "operation_id" => "open-advance",
          "occurred_on" => "2027-02-02",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2027-05-01",
          "departure_on" => "2027-05-03"
        })

      cancellation = %{
        "operation_id" => "cancel-advance",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-03",
        "group_id" => "advance",
        "expected_revision" => 2
      }

      assert %{"results" => [_, _, result]} =
               submit(build_conn(), [
                 advance,
                 credit_operation("advance", "apply-advance", 1_100, 1),
                 cancellation
               ])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert get_json("/api/v1/ledger?on=2027-02-03")["data"]["credit_liability_cents"] == 0
    end

    test "consumes equal-expiry lots by source operation identifier", %{conn: conn} do
      issue_credit(conn, "source-b", "cancel-b", 100, "2027-02-01")
      issue_credit(build_conn(), "source-a", "cancel-a", 100, "2027-02-01")

      destination =
        open_operation("destination", %{
          "operation_id" => "open-destination",
          "occurred_on" => "2027-02-02",
          "arrival_on" => "2027-05-01",
          "departure_on" => "2027-05-03"
        })

      submit(build_conn(), [
        destination,
        credit_operation("destination", "apply", 150, 1)
      ])

      assert %{"data" => %{"lots" => [remaining]}} =
               get_json("/api/v1/guests/guest-22/credit?on=2027-02-02")

      assert remaining["source_operation_id"] == "cancel-b"
      assert remaining["remaining_cents"] == 70
    end

    test "validates report dates", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_date"}} =
               conn
               |> get("/api/v1/ledger?on=tomorrow")
               |> json_response(422)

      assert %{"error" => %{"code" => "invalid_date"}} =
               build_conn()
               |> get("/api/v1/guests/guest-22/credit?on=tomorrow")
               |> json_response(422)
    end
  end

  defp issue_credit(conn, group_id, cancellation_id, cash_cents, cancelled_on) do
    opening =
      open_operation(group_id, %{
        "operation_id" => "open-#{group_id}",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-17"
      })

    cancellation = %{
      "operation_id" => cancellation_id,
      "type" => "cancel_group",
      "occurred_on" => cancelled_on,
      "group_id" => group_id,
      "refund_method" => "hotel_credit",
      "expected_revision" => 2
    }

    assert %{"results" => [_, _, result]} =
             submit(conn, [
               opening,
               payment_operation(group_id, "pay-#{group_id}", cash_cents),
               cancellation
             ])

    assert result["credit_issued_cents"] == cash_cents + div(cash_cents * 10 + 50, 100)
  end

  defp open_operation(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25_000}]
      },
      overrides
    )
  end

  defp payment_operation(group_id, operation_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => 1
    }
  end

  defp credit_operation(group_id, operation_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-02-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp get_json(path) do
    build_conn()
    |> get(path)
    |> json_response(200)
  end

  defp submit_then_get(operation, path) do
    submit(build_conn(), [operation])
    get_json(path)
  end
end
