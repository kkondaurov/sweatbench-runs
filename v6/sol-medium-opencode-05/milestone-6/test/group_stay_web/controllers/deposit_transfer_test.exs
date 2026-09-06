defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase

  test "transfers held cash atomically and evolves the payment statement", %{conn: conn} do
    transfer = transfer("transfer-1", "source", "destination", 1_500, 2, 1)

    assert %{"results" => [_, payment, _, moved]} =
             conn
             |> post("/api/v1/partner-batches", %{
               "operations" => [
                 open("source"),
                 payment("pay-1", "source", 3_500),
                 open("destination"),
                 transfer
               ]
             })
             |> json_response(200)

    assert payment["status"] == "applied"

    assert moved == %{
             "operation_id" => "transfer-1",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 1_500,
             "source_outstanding_deposit_cents" => 2_000,
             "destination_outstanding_deposit_cents" => 2_500,
             "source_revision" => 3,
             "destination_revision" => 2
           }

    assert group("source")["cash_paid_cents"] == 2_000
    assert group("destination")["cash_paid_cents"] == 1_500

    assert payment_statement("pay-1")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 1_500},
             %{"group_id" => "source", "amount_cents" => 2_000}
           ]

    assert %{"results" => [^moved]} =
             post(build_conn(), "/api/v1/partner-batches", %{"operations" => [transfer]})
             |> json_response(200)

    assert payment_statement("pay-1")["held_cents"] == 3_500
    assert ledger()["cash_held_cents"] == 3_500
  end

  test "draws newest allocations first and reductions follow transfers across groups", %{
    conn: conn
  } do
    operations = [
      open("source"),
      payment("pay-old", "source", 2_000),
      payment("pay-new", "source", 2_000),
      open("destination"),
      transfer("transfer-1", "source", "destination", 2_500),
      %{
        "operation_id" => "reduce-old",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "pay-old",
        "amount_cents" => 1_000
      }
    ]

    assert %{"results" => results} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))
    reduction = List.last(results)
    assert reduction["revision"] == 5

    assert %{"revision" => 5, "cash_paid_cents" => 1_000} = group("source")
    assert %{"revision" => 3, "cash_paid_cents" => 2_000} = group("destination")

    assert payment_statement("pay-new")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 2_000}
           ]

    assert payment_statement("pay-old")["held_by_group"] == [
             %{"group_id" => "source", "amount_cents" => 1_000}
           ]
  end

  test "resolves groups and revision guards in the required order", %{conn: conn} do
    assert %{"results" => [missing_source]} =
             conn
             |> post("/api/v1/partner-batches", %{
               "operations" => [transfer("missing-source", "absent", "also-absent", 1)]
             })
             |> json_response(200)

    assert missing_source["code"] == "group_not_found"
    assert missing_source["group_id"] == "absent"

    malformed_destination =
      transfer("missing-source-malformed-destination", "still-absent", "unused", 1)
      |> Map.delete("destination_group_id")

    assert %{"results" => [missing_before_malformed]} =
             post(build_conn(), "/api/v1/partner-batches", %{
               "operations" => [malformed_destination]
             })
             |> json_response(200)

    assert missing_before_malformed["code"] == "group_not_found"
    assert missing_before_malformed["group_id"] == "still-absent"

    assert %{"results" => [_, missing_destination]} =
             post(build_conn(), "/api/v1/partner-batches", %{
               "operations" => [
                 open("source"),
                 transfer("missing-destination", "source", "absent", 1)
               ]
             })
             |> json_response(200)

    assert missing_destination["code"] == "group_not_found"
    assert missing_destination["group_id"] == "absent"

    assert %{"results" => [_, _, stale_source, stale_destination]} =
             post(build_conn(), "/api/v1/partner-batches", %{
               "operations" => [
                 payment("pay-1", "source", 1_000),
                 open("destination"),
                 transfer("stale-source", "source", "destination", 100, 1, 99),
                 transfer("stale-destination", "source", "destination", 100, 2, 99)
               ]
             })
             |> json_response(200)

    assert stale_source["group_id"] == "source"
    assert stale_source["actual_revision"] == 2
    assert stale_destination["group_id"] == "destination"
    assert stale_destination["actual_revision"] == 1
    assert group("source")["revision"] == 2
    assert group("destination")["revision"] == 1
  end

  test "rejects transfer rules without changing either group", %{conn: conn} do
    other_guest = open("other", "guest-2")

    assert %{
             "results" => [
               _,
               _,
               _,
               _,
               _,
               different_guest,
               same_group,
               invalid_amount,
               too_much_held,
               too_much_outstanding
             ]
           } =
             conn
             |> post("/api/v1/partner-batches", %{
               "operations" => [
                 open("source"),
                 payment("pay-1", "source", 1_000),
                 other_guest,
                 open("destination"),
                 payment("destination-payment", "destination", 3_500),
                 transfer("different-guest", "source", "other", 100),
                 transfer("same-group", "source", "source", 100),
                 transfer("invalid-amount", "source", "destination", 0),
                 transfer("too-much", "source", "destination", 1_001),
                 transfer("too-much-outstanding", "source", "destination", 600)
               ]
             })
             |> json_response(200)

    assert different_guest["code"] == "invalid_transfer"
    assert same_group["code"] == "invalid_transfer"
    assert invalid_amount["code"] == "invalid_amount"
    assert too_much_held["code"] == "transfer_exceeds_held_funding"
    assert too_much_outstanding["code"] == "transfer_exceeds_outstanding"
    assert group("source")["revision"] == 2
    assert group("other")["revision"] == 1
    assert group("destination")["revision"] == 2
  end

  test "moves cash and credit in reverse allocation order and restores the original credit lot",
       %{
         conn: conn
       } do
    operations = [
      open("credit-seed"),
      payment("seed-payment", "credit-seed", 1_000),
      %{
        "operation_id" => "issue-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-10",
        "group_id" => "credit-seed",
        "refund_method" => "hotel_credit"
      },
      open("source"),
      payment("source-payment", "source", 1_000),
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-11",
        "group_id" => "source",
        "amount_cents" => 1_000
      },
      open("destination"),
      transfer("transfer-mixed", "source", "destination", 1_500),
      %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-12",
        "group_id" => "destination"
      }
    ]

    assert %{"results" => results} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert List.last(results)["refunded_cents"] == 500
    assert group("source")["cash_paid_cents"] == 500
    assert group("source")["credit_paid_cents"] == 0

    assert %{"data" => credit} =
             get(build_conn(), "/api/v1/guests/guest-1/credit?on=2026-10-12")
             |> json_response(200)

    assert credit["available_cents"] == 1_100
    assert payment_statement("source-payment")["refunded_cents"] == 500
  end

  test "transferred cash settles under the destination policy", %{conn: conn} do
    destination =
      open("destination")
      |> Map.put("rate_plan", "advance_purchase")

    operations = [
      open("source"),
      payment("pay-1", "source", 1_000),
      destination,
      transfer("transfer-1", "source", "destination", 1_000),
      %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-10",
        "group_id" => "destination"
      }
    ]

    assert %{"results" => results} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    assert List.last(results)["retained_cents"] == 1_000

    statement = payment_statement("pay-1")
    assert statement["held_cents"] == 0
    assert statement["retained_cents"] == 1_000
    assert statement["held_by_group"] == []
    assert ledger()["cash_held_cents"] == 0
    assert ledger()["cash_retained_cents"] == 1_000
  end

  test "chargebacks remove transferred allocations and increment every changed group", %{
    conn: conn
  } do
    operations = [
      open("source"),
      payment("pay-1", "source", 4_000),
      open("destination"),
      transfer("transfer-1", "source", "destination", 1_500),
      %{
        "operation_id" => "chargeback-1",
        "type" => "charge_back_payment",
        "payment_operation_id" => "pay-1",
        "expected_revision" => 3
      }
    ]

    assert %{"results" => results} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    chargeback = List.last(results)
    assert chargeback["status"] == "applied"
    assert chargeback["charged_back_cents"] == 4_000
    assert chargeback["revision"] == 4
    assert %{"revision" => 4, "cash_paid_cents" => 0} = group("source")
    assert %{"revision" => 3, "cash_paid_cents" => 0} = group("destination")

    statement = payment_statement("pay-1")
    assert statement["charged_back_cents"] == 4_000
    assert statement["held_by_group"] == []
  end

  test "inactive transfer errors identify the first inactive group", %{conn: conn} do
    cancel_source = %{
      "operation_id" => "cancel-source",
      "type" => "cancel_group",
      "occurred_on" => "2026-10-10",
      "group_id" => "source"
    }

    cancel_destination = %{
      "operation_id" => "cancel-destination",
      "type" => "cancel_group",
      "occurred_on" => "2026-10-10",
      "group_id" => "destination"
    }

    assert %{"results" => [_, _, _, source_inactive, _, _, destination_inactive]} =
             conn
             |> post("/api/v1/partner-batches", %{
               "operations" => [
                 open("source"),
                 cancel_source,
                 open("destination"),
                 transfer("source-inactive", "source", "destination", 1),
                 open("active-source"),
                 cancel_destination,
                 transfer("destination-inactive", "active-source", "destination", 1)
               ]
             })
             |> json_response(200)

    assert source_inactive["code"] == "group_not_active"
    assert source_inactive["group_id"] == "source"
    assert destination_inactive["code"] == "group_not_active"
    assert destination_inactive["group_id"] == "destination"
  end

  defp open(group_id, guest_id \\ "guest-1") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "hotel-#{group_id}",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-12",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 10_000}]
    }
  end

  defp payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(
         operation_id,
         source,
         destination,
         amount,
         source_revision \\ nil,
         destination_revision \\ nil
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-05",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
    |> maybe_put("expected_revision", source_revision)
    |> maybe_put("destination_expected_revision", destination_revision)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp group(group_id),
    do:
      get(build_conn(), "/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")

  defp payment_statement(payment_id),
    do:
      get(build_conn(), "/api/v1/payments/#{payment_id}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp ledger,
    do:
      get(build_conn(), "/api/v1/ledger?on=2026-10-10")
      |> json_response(200)
      |> Map.fetch!("data")
end
