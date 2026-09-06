defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(group_id, guest_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-#{group_id}",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: group_id,
        guest_id: guest_id,
        property_id: "ams-canal",
        arrival_on: "2027-02-01",
        departure_on: "2027-02-03",
        rate_plan: "flexible",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 5_000}]
      },
      overrides
    )
  end

  defp payment(group_id, operation_id, amount_cents) do
    %{
      operation_id: operation_id,
      type: "record_cash_payment",
      occurred_on: "2026-10-03",
      group_id: group_id,
      amount_cents: amount_cents
    }
  end

  test "fixes the policy at booking and exposes the policy date", %{conn: conn} do
    submit(conn, [
      open_operation("old-policy", "guest-old", %{occurred_on: "2026-12-31"}),
      open_operation("new-policy", "guest-new", %{occurred_on: "2027-01-01"}),
      open_operation("advance", "guest-advance", %{rate_plan: "advance_purchase"})
    ])
    |> json_response(200)

    assert get(conn, "/api/v1/groups/old-policy")
           |> json_response(200)
           |> get_in(["data", "policy_version"]) == "flex-14"

    assert get(conn, "/api/v1/groups/old-policy")
           |> json_response(200)
           |> get_in(["data", "refundable_until"]) == "2027-01-18"

    assert get(conn, "/api/v1/groups/new-policy")
           |> json_response(200)
           |> get_in(["data", "policy_version"]) == "flex-30"

    assert get(conn, "/api/v1/groups/new-policy")
           |> json_response(200)
           |> get_in(["data", "refundable_until"]) == "2027-01-02"

    assert get(conn, "/api/v1/groups/advance")
           |> json_response(200)
           |> get_in(["data", "refundable_until"]) == nil

    result =
      submit(conn, [
        %{
          operation_id: "move-new",
          type: "reschedule_group",
          occurred_on: "2027-01-01",
          group_id: "new-policy",
          new_arrival_on: "2027-02-10"
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result["policy_version"] == "flex-30"
    assert result["refundable_until"] == "2027-01-11"
    assert result["new_departure_on"] == "2027-02-12"
  end

  test "converts refundable cash to expiring credit and restores applied credit", %{conn: conn} do
    submit(conn, [
      open_operation("source", "guest-credit"),
      payment("source", "pay-source", 1_000)
    ])
    |> json_response(200)

    result =
      submit(conn, [
        %{
          operation_id: "cancel-source",
          type: "cancel_group",
          occurred_on: "2027-01-18",
          group_id: "source",
          refund_method: "hotel_credit",
          expected_revision: 2
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result == %{
             "operation_id" => "cancel-source",
             "status" => "applied",
             "group_id" => "source",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 1_100,
             "revision" => 3
           }

    assert get(conn, "/api/v1/guests/guest-credit/credit?on=2028-01-17")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 1_100

    assert get(conn, "/api/v1/guests/guest-credit/credit?on=2028-01-18")
           |> json_response(200)
           |> get_in(["data", "lots", Access.at(0), "expires_on"]) == "2028-01-18"

    assert get(conn, "/api/v1/guests/guest-credit/credit?on=2028-01-19")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 0

    assert get(conn, "/api/v1/ledger?on=2028-01-19")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0

    assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 1_000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0,
               "credit_liability_cents" => 1_100
             }
           }

    submit(conn, [open_operation("restore-target", "guest-credit")]) |> json_response(200)

    apply_result =
      submit(conn, [
        %{
          operation_id: "apply-credit",
          type: "apply_hotel_credit",
          occurred_on: "2027-02-01",
          group_id: "restore-target",
          amount_cents: 700,
          expected_revision: 1
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert apply_result["outstanding_deposit_cents"] == 1_300

    group = get(conn, "/api/v1/groups/restore-target") |> json_response(200)
    assert group["data"]["deposit_paid_cents"] == 700
    assert group["data"]["cash_paid_cents"] == 0
    assert group["data"]["credit_paid_cents"] == 700

    cancel_result =
      submit(conn, [
        %{
          operation_id: "cancel-restore",
          type: "cancel_group",
          occurred_on: "2027-01-18",
          group_id: "restore-target",
          expected_revision: 2
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert cancel_result["refunded_cents"] == 0
    assert cancel_result["retained_cents"] == 0
    assert cancel_result["credit_issued_cents"] == 0

    assert get(conn, "/api/v1/guests/guest-credit/credit?on=2027-02-01")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 1_100
  end

  test "non-refundable cancellation rejects credit refunds and consumes applied credit", %{
    conn: conn
  } do
    submit(conn, [
      open_operation("source", "guest-nonrefundable"),
      payment("source", "pay-source", 1_000)
    ])
    |> json_response(200)

    submit(conn, [
      %{
        operation_id: "cancel-source",
        type: "cancel_group",
        occurred_on: "2027-01-18",
        group_id: "source",
        refund_method: "hotel_credit"
      }
    ])
    |> json_response(200)

    submit(conn, [open_operation("target", "guest-nonrefundable")]) |> json_response(200)

    submit(conn, [
      %{
        operation_id: "apply-credit",
        type: "apply_hotel_credit",
        occurred_on: "2027-01-01",
        group_id: "target",
        amount_cents: 700
      }
    ])
    |> json_response(200)

    rejected =
      submit(conn, [
        %{
          operation_id: "reject-credit-refund",
          type: "cancel_group",
          occurred_on: "2027-01-25",
          group_id: "target",
          refund_method: "hotel_credit",
          expected_revision: 2
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert rejected["code"] == "refund_method_not_available"

    result =
      submit(conn, [
        %{
          operation_id: "cancel-target",
          type: "cancel_group",
          occurred_on: "2027-01-25",
          group_id: "target",
          expected_revision: 2
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result["retained_cents"] == 0

    assert get(conn, "/api/v1/guests/guest-nonrefundable/credit?on=2027-01-25")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 400

    assert get(conn, "/api/v1/ledger?on=2027-01-25")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 400
  end

  test "restoring credit after its expiry removes the expired liability", %{conn: conn} do
    submit(conn, [
      open_operation("source", "guest-expired", %{
        occurred_on: "2026-01-01",
        arrival_on: "2027-02-01",
        departure_on: "2027-02-03"
      }),
      payment("source", "pay-source", 1_000)
    ])
    |> json_response(200)

    submit(conn, [
      %{
        operation_id: "cancel-source",
        type: "cancel_group",
        occurred_on: "2026-01-01",
        group_id: "source",
        refund_method: "hotel_credit"
      }
    ])
    |> json_response(200)

    submit(conn, [open_operation("target", "guest-expired")]) |> json_response(200)

    submit(conn, [
      %{
        operation_id: "apply-credit",
        type: "apply_hotel_credit",
        occurred_on: "2026-06-01",
        group_id: "target",
        amount_cents: 700
      }
    ])
    |> json_response(200)

    submit(conn, [
      %{
        operation_id: "cancel-target",
        type: "cancel_group",
        occurred_on: "2027-01-02",
        group_id: "target"
      }
    ])
    |> json_response(200)

    assert get(conn, "/api/v1/guests/guest-expired/credit?on=2027-01-02")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 0

    assert get(conn, "/api/v1/ledger?on=2027-01-02")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0

    assert Repo.get_by(Group, group_id: "target").status == "cancelled"
  end

  test "applies credit by expiry and source operation order", %{conn: conn} do
    submit(conn, [
      open_operation("source-z", "guest-order"),
      payment("source-z", "pay-z", 1_000),
      open_operation("source-a", "guest-order"),
      payment("source-a", "pay-a", 1_000)
    ])
    |> json_response(200)

    submit(conn, [
      %{
        operation_id: "z-source",
        type: "cancel_group",
        occurred_on: "2027-01-18",
        group_id: "source-z",
        refund_method: "hotel_credit"
      },
      %{
        operation_id: "a-source",
        type: "cancel_group",
        occurred_on: "2027-01-18",
        group_id: "source-a",
        refund_method: "hotel_credit"
      },
      open_operation("order-target", "guest-order")
    ])
    |> json_response(200)

    submit(conn, [
      %{
        operation_id: "apply-order",
        type: "apply_hotel_credit",
        occurred_on: "2027-01-18",
        group_id: "order-target",
        amount_cents: 1_500
      }
    ])
    |> json_response(200)

    assert get(conn, "/api/v1/guests/guest-order/credit?on=2027-01-18")
           |> json_response(200)
           |> get_in(["data", "lots"]) == [
             %{
               "source_operation_id" => "z-source",
               "remaining_cents" => 700,
               "expires_on" => "2028-01-18"
             }
           ]
  end
end
