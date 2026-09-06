defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  test "assigns and preserves policy versions across the booking boundary", %{conn: conn} do
    operations = [
      open_operation("old", %{"occurred_on" => "2026-12-31"}),
      open_operation("new", %{
        "operation_id" => "open-new",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-31",
        "departure_on" => "2027-04-03"
      }),
      %{
        "operation_id" => "move-new",
        "type" => "reschedule_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "new",
        "new_arrival_on" => "2027-04-30"
      },
      open_operation("advance", %{
        "operation_id" => "open-advance",
        "rate_plan" => "advance_purchase"
      })
    ]

    assert %{"results" => [_, _, move, _]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    assert move["policy_version"] == "flex-30"
    assert move["refundable_until"] == "2027-03-31"

    assert %{"data" => old} =
             build_conn() |> get("/api/v1/groups/old") |> json_response(200)

    assert old["policy_version"] == "flex-14"
    assert old["refundable_until"] == "2026-11-26"
    assert old["cash_paid_cents"] == 0
    assert old["credit_paid_cents"] == 0

    assert %{"data" => advance} =
             build_conn() |> get("/api/v1/groups/advance") |> json_response(200)

    assert advance["policy_version"] == "advance-nonrefundable"
    assert advance["refundable_until"] == nil
  end

  test "uses the inclusive policy cutoff when settling cancellation", %{conn: conn} do
    operations = [
      open_operation("boundary", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-31",
        "departure_on" => "2027-04-03"
      }),
      payment("boundary", 9_000),
      cancel("boundary", "2027-03-01")
    ]

    assert %{"results" => [_, _, cancellation]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    assert cancellation["refunded_cents"] == 9_000
    assert cancellation["retained_cents"] == 0
    assert cancellation["credit_issued_cents"] == 0
  end

  test "converts refundable cash to expiring hotel credit with a rounded bonus", %{conn: conn} do
    operations = [
      open_operation("source"),
      payment("source", 5_005),
      cancel("source", "2026-10-10", "hotel_credit")
    ]

    assert %{"results" => [_, _, cancellation]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    assert cancellation["refunded_cents"] == 0
    assert cancellation["retained_cents"] == 0
    assert cancellation["credit_issued_cents"] == 5_506

    assert %{"data" => credit} =
             build_conn()
             |> get("/api/v1/guests/guest-1/credit?on=2027-10-10")
             |> json_response(200)

    assert credit == %{
             "guest_id" => "guest-1",
             "available_cents" => 5_506,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-source",
                 "remaining_cents" => 5_506,
                 "expires_on" => "2027-10-10"
               }
             ]
           }

    assert %{"data" => ledger} =
             build_conn() |> get("/api/v1/ledger?on=2027-10-10") |> json_response(200)

    assert ledger["cash_converted_to_credit_cents"] == 5_005
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["credit_liability_cents"] == 5_506

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             build_conn()
             |> get("/api/v1/guests/guest-1/credit?on=2027-10-11")
             |> json_response(200)
  end

  test "applies credit, pauses expiry, and drops an expired restoration", %{conn: conn} do
    issue_credit(conn, 5_000)

    funding_operations = [
      open_operation("target", %{
        "operation_id" => "open-target",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-12-10",
        "departure_on" => "2027-12-13"
      }),
      apply_credit("target", 5_500, "2027-10-10", 1)
    ]

    assert %{"results" => [_, applied]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{"operations" => funding_operations})
             |> json_response(200)

    assert applied == %{
             "operation_id" => "credit-target",
             "status" => "applied",
             "group_id" => "target",
             "amount_cents" => 5_500,
             "outstanding_deposit_cents" => 3_500,
             "revision" => 2
           }

    assert %{"data" => %{"credit_liability_cents" => 5_500}} =
             build_conn() |> get("/api/v1/ledger?on=2028-01-01") |> json_response(200)

    assert %{"results" => [cancelled]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{
               "operations" => [cancel("target", "2027-10-11")]
             })
             |> json_response(200)

    assert cancelled["credit_issued_cents"] == 0

    assert %{"data" => group} =
             build_conn() |> get("/api/v1/groups/target") |> json_response(200)

    assert group["cash_paid_cents"] == 0
    assert group["credit_paid_cents"] == 0

    assert %{"data" => %{"available_cents" => 0}} =
             build_conn()
             |> get("/api/v1/guests/guest-1/credit?on=2027-10-11")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             build_conn() |> get("/api/v1/ledger?on=2027-10-11") |> json_response(200)
  end

  test "consumes equal-expiry lots by source operation identifier", %{conn: conn} do
    operations = [
      open_operation("z-source"),
      payment("z-source", 1_000),
      cancel("z-source", "2026-10-10", "hotel_credit"),
      open_operation("a-source"),
      payment("a-source", 1_000),
      cancel("a-source", "2026-10-10", "hotel_credit"),
      open_operation("target", %{"operation_id" => "open-target"}),
      apply_credit("target", 1_500, "2026-10-11", 1)
    ]

    assert %{"results" => results} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => credit} =
             build_conn()
             |> get("/api/v1/guests/guest-1/credit?on=2026-10-11")
             |> json_response(200)

    assert credit["available_cents"] == 700

    assert credit["lots"] == [
             %{
               "source_operation_id" => "cancel-z-source",
               "remaining_cents" => 700,
               "expires_on" => "2027-10-10"
             }
           ]
  end

  test "restores unexpired credit and consumes it on non-refundable cancellation", %{conn: conn} do
    issue_credit(conn, 8_000)

    refundable = [
      open_operation("refundable", %{"operation_id" => "open-refundable"}),
      apply_credit("refundable", 4_000, "2026-10-11", 1),
      cancel("refundable", "2026-10-12")
    ]

    assert %{"results" => [_, _, restored]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{"operations" => refundable})
             |> json_response(200)

    assert restored["refunded_cents"] == 0

    nonrefundable = [
      open_operation("nonref", %{
        "operation_id" => "open-nonref",
        "rate_plan" => "advance_purchase"
      }),
      apply_credit("nonref", 8_800, "2026-10-13", 1),
      cancel("nonref", "2026-10-14")
    ]

    assert %{"results" => [_, _, consumed]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{"operations" => nonrefundable})
             |> json_response(200)

    assert consumed["retained_cents"] == 0

    assert %{"data" => %{"available_cents" => 0}} =
             build_conn()
             |> get("/api/v1/guests/guest-1/credit?on=2026-10-15")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             build_conn() |> get("/api/v1/ledger?on=2026-10-15") |> json_response(200)
  end

  test "rejects unavailable or insufficient credit after checking revision", %{conn: conn} do
    operations = [
      open_operation("advance", %{"rate_plan" => "advance_purchase"}),
      Map.put(cancel("advance", "2026-10-10", "hotel_credit"), "expected_revision", 9),
      Map.put(
        cancel("advance", "2026-10-10", "hotel_credit"),
        "operation_id",
        "cancel-advance-current"
      ),
      apply_credit("advance", 100, "2026-10-10", 1)
    ]

    assert %{"results" => [_, stale, unavailable, insufficient]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    assert stale["code"] == "stale_revision"
    assert unavailable["code"] == "refund_method_not_available"
    assert insufficient["code"] == "insufficient_credit"
    assert insufficient["actual_revision"] == nil

    assert %{"data" => %{"status" => "active", "revision" => 1}} =
             build_conn() |> get("/api/v1/groups/advance") |> json_response(200)
  end

  defp issue_credit(conn, cash) do
    operations = [
      open_operation("source"),
      payment("source", cash),
      cancel("source", "2026-10-10", "hotel_credit")
    ]

    assert %{"results" => [_, _, %{"status" => "applied"}]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
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

  defp payment(group_id, amount) do
    %{
      "operation_id" => "pay-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp apply_credit(group_id, amount, occurred_on, expected_revision) do
    %{
      "operation_id" => "credit-#{group_id}",
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end

  defp cancel(group_id, occurred_on, refund_method \\ "cash") do
    %{
      "operation_id" => "cancel-#{group_id}",
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end
end
