defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 50_000}]
      },
      overrides
    )
  end

  defp payment(group_id, amount_cents) do
    %{
      "operation_id" => "pay-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancellation(group_id, operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      },
      overrides
    )
  end

  defp apply_credit(group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "credit-#{group_id}",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-02",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp submit(conn, operations),
    do: post(conn, ~p"/api/v1/partner-batches", %{operations: operations})

  test "assigns policy at booking and recomputes its cutoff after rescheduling", %{conn: conn} do
    operations = [
      open_operation(),
      open_operation(%{
        "operation_id" => "open-new",
        "group_id" => "new-policy",
        "occurred_on" => "2027-01-01"
      }),
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase"
      }),
      %{
        "operation_id" => "move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-1",
        "new_arrival_on" => "2027-04-10"
      }
    ]

    conn = submit(conn, operations)
    assert %{"results" => [_, _, _, moved]} = json_response(conn, 200)
    assert moved["policy_version"] == "flex-14"
    assert moved["refundable_until"] == "2027-03-27"

    old =
      get(recycle(conn), ~p"/api/v1/groups/group-1") |> json_response(200) |> Map.fetch!("data")

    new =
      get(recycle(conn), ~p"/api/v1/groups/new-policy")
      |> json_response(200)
      |> Map.fetch!("data")

    advance =
      get(recycle(conn), ~p"/api/v1/groups/advance") |> json_response(200) |> Map.fetch!("data")

    assert {old["policy_version"], old["refundable_until"]} == {"flex-14", "2027-03-27"}
    assert {new["policy_version"], new["refundable_until"]} == {"flex-30", "2027-02-08"}

    assert {advance["policy_version"], advance["refundable_until"]} ==
             {"advance-nonrefundable", nil}
  end

  test "converts refundable cash to bonus credit and reports expiry", %{conn: conn} do
    source =
      open_operation(%{
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25}]
      })

    conn =
      submit(conn, [source, payment("group-1", 5), cancellation("group-1", "cancel-17")])

    assert %{"results" => [_, _, result]} = json_response(conn, 200)
    assert result["credit_issued_cents"] == 6
    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 0

    credit =
      get(recycle(conn), ~p"/api/v1/guests/guest-1/credit?on=2028-01-01")
      |> json_response(200)

    assert credit == %{
             "data" => %{
               "guest_id" => "guest-1",
               "available_cents" => 6,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 6,
                   "expires_on" => "2028-01-01"
                 }
               ]
             }
           }

    expired = get(recycle(conn), ~p"/api/v1/guests/guest-1/credit?on=2028-01-02")
    assert get_in(json_response(expired, 200), ["data", "available_cents"]) == 0

    ledger = get(recycle(conn), ~p"/api/v1/ledger?on=2028-01-01") |> json_response(200)
    assert ledger["data"]["cash_converted_to_credit_cents"] == 5
    assert ledger["data"]["credit_liability_cents"] == 6
    assert ledger["data"]["cash_held_cents"] == 0
  end

  test "consumes equal-expiry lots by source id and restores allocations", %{conn: conn} do
    source_a = open_operation(%{"operation_id" => "open-a", "group_id" => "source-a"})
    source_z = open_operation(%{"operation_id" => "open-z", "group_id" => "source-z"})

    target =
      open_operation(%{
        "operation_id" => "open-target",
        "group_id" => "target",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-05-01",
        "departure_on" => "2027-05-02"
      })

    operations = [
      source_z,
      payment("source-z", 1_000),
      cancellation("source-z", "z-source"),
      source_a,
      payment("source-a", 1_000),
      cancellation("source-a", "a-source"),
      target,
      payment("target", 500),
      apply_credit("target", 1_500)
    ]

    conn = submit(conn, operations)
    assert %{"results" => results} = json_response(conn, 200)
    applied = List.last(results)
    assert applied["status"] == "applied"
    assert applied["revision"] == 3

    credit = get(recycle(conn), ~p"/api/v1/guests/guest-1/credit?on=2027-01-02")
    assert %{"data" => %{"available_cents" => 700, "lots" => [lot]}} = json_response(credit, 200)
    assert lot["source_operation_id"] == "z-source"

    group = get(recycle(conn), ~p"/api/v1/groups/target") |> json_response(200)
    assert group["data"]["credit_paid_cents"] == 1_500
    assert group["data"]["cash_paid_cents"] == 500
    assert group["data"]["deposit_paid_cents"] == 2_000

    ledger = get(recycle(conn), ~p"/api/v1/ledger?on=2027-01-02") |> json_response(200)
    assert ledger["data"]["credit_liability_cents"] == 2_200

    conn =
      submit(recycle(conn), [
        cancellation("target", "cancel-target", %{
          "occurred_on" => "2027-03-31",
          "refund_method" => "cash",
          "expected_revision" => 3
        })
      ])

    cancellation_result = get_in(json_response(conn, 200), ["results", Access.at(0)])
    assert cancellation_result["credit_issued_cents"] == 0
    assert cancellation_result["refunded_cents"] == 500
    restored = get(recycle(conn), ~p"/api/v1/guests/guest-1/credit?on=2027-03-31")
    assert get_in(json_response(restored, 200), ["data", "available_cents"]) == 2_200
    cancelled_group = get(recycle(conn), ~p"/api/v1/groups/target") |> json_response(200)
    assert cancelled_group["data"]["credit_paid_cents"] == 1_500
    assert cancelled_group["data"]["deposit_paid_cents"] == 2_000
    assert cancelled_group["data"]["outstanding_deposit_cents"] == 0
  end

  test "expired restored credit and non-refundable consumption reduce liability", %{conn: conn} do
    target =
      open_operation(%{
        "operation_id" => "open-target",
        "group_id" => "target",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2028-02-01",
        "departure_on" => "2028-02-02"
      })

    conn =
      submit(conn, [
        open_operation(),
        payment("group-1", 1_000),
        cancellation("group-1", "source"),
        target,
        apply_credit("target", 1_100),
        cancellation("target", "late-cancel", %{
          "occurred_on" => "2028-01-02",
          "refund_method" => "cash"
        })
      ])

    assert %{"results" => results} = json_response(conn, 200)
    assert List.last(results)["status"] == "applied"
    ledger = get(recycle(conn), ~p"/api/v1/ledger?on=2028-01-02") |> json_response(200)
    assert ledger["data"]["credit_liability_cents"] == 0

    advance =
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase"
      })

    conn =
      submit(recycle(conn), [
        advance,
        cancellation("advance", "reject", %{"expected_revision" => 1}),
        cancellation("advance", "stale", %{"expected_revision" => 9})
      ])

    assert %{"results" => [_, rejected, stale]} = json_response(conn, 200)
    assert rejected["code"] == "refund_method_not_available"
    assert stale["code"] == "stale_revision"
    advance_read = get(recycle(conn), ~p"/api/v1/groups/advance") |> json_response(200)
    assert advance_read["data"]["status"] == "active"
    assert advance_read["data"]["revision"] == 1
  end

  test "validates credit amount, availability, outstanding, and report dates", %{conn: conn} do
    conn =
      submit(conn, [
        open_operation(),
        apply_credit("group-1", 0),
        apply_credit("group-1", 1, %{"operation_id" => "insufficient"}),
        apply_credit("group-1", 20_000, %{"operation_id" => "excessive"})
      ])

    assert %{"results" => [_, invalid, insufficient, excessive]} = json_response(conn, 200)
    assert invalid["code"] == "invalid_amount"
    assert insufficient["code"] == "insufficient_credit"
    assert excessive["code"] == "payment_exceeds_outstanding"

    assert json_response(get(recycle(conn), "/api/v1/ledger?on=bad"), 422) ==
             %{"error" => %{"code" => "invalid_date"}}

    assert json_response(get(recycle(conn), "/api/v1/guests/guest-1/credit?on=bad"), 422) ==
             %{"error" => %{"code" => "invalid_date"}}
  end
end
