defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  test "fixes cancellation policy at booking and uses the inclusive refund boundary", %{
    conn: conn
  } do
    response =
      submit(conn, [
        open_group("open-legacy", "legacy", "2026-12-31", "2027-02-20", "2027-02-21"),
        open_group("open-modern", "modern", "2027-01-01", "2027-02-20", "2027-02-21"),
        cash_payment("pay-modern", "modern", "2027-01-02", 100, 1),
        cancel("cancel-modern", "modern", "2027-01-21", 2),
        open_group("open-advance", "advance", "2027-01-01", "2027-02-20", "2027-02-21", %{
          "rate_plan" => "advance_purchase"
        }),
        reschedule("move-legacy", "legacy", "2027-01-10", "2027-03-01", 1)
      ])

    assert Enum.at(response["results"], 3) == %{
             "operation_id" => "cancel-modern",
             "status" => "applied",
             "group_id" => "modern",
             "refunded_cents" => 100,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert Enum.at(response["results"], 5) == %{
             "operation_id" => "move-legacy",
             "status" => "applied",
             "group_id" => "legacy",
             "new_arrival_on" => "2027-03-01",
             "new_departure_on" => "2027-03-02",
             "policy_version" => "flex-14",
             "refundable_until" => "2027-02-15",
             "revision" => 2
           }

    assert group(conn, "legacy") |> Map.take(["policy_version", "refundable_until"]) == %{
             "policy_version" => "flex-14",
             "refundable_until" => "2027-02-15"
           }

    assert group(conn, "modern") |> Map.take(["policy_version", "refundable_until"]) == %{
             "policy_version" => "flex-30",
             "refundable_until" => "2027-01-21"
           }

    assert group(conn, "advance") |> Map.take(["policy_version", "refundable_until"]) == %{
             "policy_version" => "advance-nonrefundable",
             "refundable_until" => nil
           }
  end

  test "issues, consumes, and restores credit while preserving credit liability", %{conn: conn} do
    response =
      submit(conn, [
        open_group("open-source-1", "source-1", "2027-01-01", "2027-03-01", "2027-03-02"),
        cash_payment("pay-source-1", "source-1", "2027-01-02", 1_005, 1),
        cancel("cancel-source-1", "source-1", "2027-01-30", 2, "hotel_credit"),
        open_group("open-source-2", "source-2", "2027-01-01", "2027-03-20", "2027-03-21"),
        cash_payment("pay-source-2", "source-2", "2027-01-02", 500, 1),
        cancel("cancel-source-2", "source-2", "2027-02-01", 2, "hotel_credit"),
        open_group("open-target", "target", "2027-01-01", "2027-03-15", "2027-03-16"),
        apply_credit("apply-target", "target", "2027-02-05", 1_200, 1),
        cancel("cancel-target", "target", "2027-02-10", 2)
      ])

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "cancel-source-1",
             "status" => "applied",
             "group_id" => "source-1",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 1_106,
             "revision" => 3
           }

    assert Enum.at(response["results"], 7) == %{
             "operation_id" => "apply-target",
             "status" => "applied",
             "group_id" => "target",
             "amount_cents" => 1_200,
             "outstanding_deposit_cents" => 800,
             "revision" => 2
           }

    assert Enum.at(response["results"], 8) == %{
             "operation_id" => "cancel-target",
             "status" => "applied",
             "group_id" => "target",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert group(conn, "target")
           |> Map.take([
             "status",
             "deposit_paid_cents",
             "cash_paid_cents",
             "credit_paid_cents",
             "outstanding_deposit_cents"
           ]) == %{
             "status" => "cancelled",
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 0
           }

    assert credit(conn, "guest-22", "2027-02-10") == %{
             "guest_id" => "guest-22",
             "available_cents" => 1_656,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-source-1",
                 "remaining_cents" => 1_106,
                 "expires_on" => "2028-01-31"
               },
               %{
                 "source_operation_id" => "cancel-source-2",
                 "remaining_cents" => 550,
                 "expires_on" => "2028-02-02"
               }
             ]
           }

    assert ledger(conn, "2027-02-10") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 1_505,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 1_656,
             "credit_shortfall_cents" => 0
           }
  end

  test "rejects unavailable credit methods and insufficient credit without advancing revisions",
       %{
         conn: conn
       } do
    response =
      submit(conn, [
        open_group("open-advance", "advance", "2027-01-01", "2027-03-01", "2027-03-02", %{
          "rate_plan" => "advance_purchase"
        }),
        cash_payment("pay-advance", "advance", "2027-01-02", 100, 1),
        cancel("credit-advance", "advance", "2027-01-03", 2, "hotel_credit"),
        cash_payment("pay-after-rejection", "advance", "2027-01-04", 100, 2),
        open_group("open-target", "target", "2027-01-01", "2027-03-01", "2027-03-02"),
        apply_credit("insufficient", "target", "2027-01-02", 1, 1),
        apply_credit("stale", "target", "2027-01-02", 0, 0),
        cash_payment("pay-target", "target", "2027-01-03", 1, 1)
      ])

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "credit-advance",
             "status" => "rejected",
             "code" => "refund_method_not_available"
           }

    assert Enum.at(response["results"], 3)["revision"] == 3

    assert Enum.at(response["results"], 5) == %{
             "operation_id" => "insufficient",
             "status" => "rejected",
             "code" => "insufficient_credit"
           }

    assert Enum.at(response["results"], 6) == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "target",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    assert group(conn, "advance")["status"] == "active"
    assert group(conn, "target")["revision"] == 2
  end

  test "expires restored credit when its paused lot is already expired", %{conn: conn} do
    submit(conn, [
      open_group("open-source", "source", "2027-01-01", "2027-03-01", "2027-03-02"),
      cash_payment("pay-source", "source", "2027-01-02", 105, 1),
      cancel("cancel-source", "source", "2027-01-30", 2, "hotel_credit"),
      open_group("open-target", "target", "2027-01-01", "2028-03-15", "2028-03-16"),
      apply_credit("apply-target", "target", "2028-01-30", 116, 1)
    ])

    assert ledger(conn, "2028-02-01")["credit_liability_cents"] == 116

    response = submit(conn, [cancel("cancel-target", "target", "2028-02-01", 2)])

    assert response["results"] == [
             %{
               "operation_id" => "cancel-target",
               "status" => "applied",
               "group_id" => "target",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
           ]

    assert credit(conn, "guest-22", "2028-02-01") == %{
             "guest_id" => "guest-22",
             "available_cents" => 0,
             "lots" => []
           }

    assert ledger(conn, "2028-02-01")["credit_liability_cents"] == 0
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp group(conn, group_id) do
    conn
    |> get(~p"/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp credit(conn, guest_id, on) do
    conn
    |> get(~p"/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn, on) do
    conn
    |> get(~p"/api/v1/ledger?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open_group(operation_id, group_id, booked_on, arrival_on, departure_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => booked_on,
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => arrival_on,
        "departure_on" => departure_on,
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "#{group_id}-room", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp cash_payment(operation_id, group_id, occurred_on, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp apply_credit(operation_id, group_id, occurred_on, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp cancel(operation_id, group_id, occurred_on, expected_revision, refund_method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision,
      "refund_method" => refund_method
    }
  end

  defp reschedule(operation_id, group_id, occurred_on, new_arrival_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reschedule_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "new_arrival_on" => new_arrival_on,
      "expected_revision" => expected_revision
    }
  end
end
