defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  test "a durable transfer draws newest cash or credit and preserves provenance", %{conn: conn} do
    transfer = transfer_operation("transfer", "source", "destination", 150, 3, 1)

    operations = [
      open_operation("credit-seed", "guest", 1),
      payment_operation("seed-pay", "credit-seed", 100, 1),
      cancel_operation("issue-credit", "credit-seed", 2, "hotel_credit"),
      open_operation("source", "guest", 2),
      open_operation("destination", "guest", 2),
      payment_operation("source-pay", "source", 100, 1),
      credit_operation("source-credit", "source", 100, 2),
      transfer,
      transfer
    ]

    %{"results" => results} = post_batch(conn, operations)
    original = Enum.at(results, 7)
    assert Enum.at(results, 8) == original

    assert original == %{
             "operation_id" => "transfer",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 150,
             "source_outstanding_deposit_cents" => 150,
             "destination_outstanding_deposit_cents" => 50,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert room_funding("source") == [
             %{"cash_paid_cents" => 50, "credit_paid_cents" => 0},
             %{"cash_paid_cents" => 0, "credit_paid_cents" => 0}
           ]

    assert room_funding("destination") == [
             %{"cash_paid_cents" => 0, "credit_paid_cents" => 100},
             %{"cash_paid_cents" => 50, "credit_paid_cents" => 0}
           ]

    assert get_payment("source-pay")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 50},
             %{"group_id" => "source", "amount_cents" => 50}
           ]

    assert get_ledger() |> Map.take(ledger_fields()) == %{
             "cash_held_cents" => 100,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 100,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 110,
             "credit_shortfall_cents" => 0
           }

    %{"results" => [cancellation]} =
      post_batch(build_conn(), [cancel_operation("cancel-destination", "destination", 2, "cash")])

    assert cancellation["refunded_cents"] == 50
    assert get_credit("guest")["available_cents"] == 110

    statement = get_payment("source-pay")
    assert statement["held_cents"] == 50
    assert statement["refunded_cents"] == 50
    assert statement["held_by_group"] == [%{"group_id" => "source", "amount_cents" => 50}]
  end

  test "reductions and chargebacks follow transferred cash and revise every changed group", %{
    conn: conn
  } do
    operations = [
      open_operation("source", "guest", 2),
      open_operation("destination", "guest", 2),
      payment_operation("pay", "source", 200, 1),
      transfer_operation("first-transfer", "source", "destination", 75, 2, 1),
      reduce_operation("reduce", "pay", 100, 3)
    ]

    %{"results" => results} = post_batch(conn, operations)

    assert List.last(results) == %{
             "operation_id" => "reduce",
             "status" => "applied",
             "payment_operation_id" => "pay",
             "group_id" => "source",
             "amount_cents" => 100,
             "outstanding_deposit_cents" => 100,
             "revision" => 4
           }

    assert get_group("source") |> Map.take(["deposit_paid_cents", "revision"]) == %{
             "deposit_paid_cents" => 100,
             "revision" => 4
           }

    assert get_group("destination") |> Map.take(["deposit_paid_cents", "revision"]) == %{
             "deposit_paid_cents" => 0,
             "revision" => 3
           }

    assert get_payment("pay")["held_by_group"] == [
             %{"group_id" => "source", "amount_cents" => 100}
           ]

    %{"results" => [_, chargeback]} =
      post_batch(build_conn(), [
        transfer_operation("second-transfer", "source", "destination", 50, 4, 3),
        chargeback_operation("chargeback", "pay", 5)
      ])

    assert chargeback == %{
             "operation_id" => "chargeback",
             "status" => "applied",
             "payment_operation_id" => "pay",
             "group_id" => "source",
             "charged_back_cents" => 100,
             "outstanding_deposit_cents" => 200,
             "revision" => 6
           }

    assert get_group("source") |> Map.take(["deposit_paid_cents", "revision"]) == %{
             "deposit_paid_cents" => 0,
             "revision" => 6
           }

    assert get_group("destination") |> Map.take(["deposit_paid_cents", "revision"]) == %{
             "deposit_paid_cents" => 0,
             "revision" => 5
           }

    statement = get_payment("pay")
    assert statement["held_by_group"] == []
    assert statement["reduced_cents"] == 100
    assert statement["charged_back_cents"] == 100
  end

  test "transfer validation follows existence, revision, and domain precedence", %{conn: conn} do
    operations = [
      open_operation("source", "guest", 1),
      open_operation("destination", "guest", 1),
      open_operation("other-guest", "someone-else", 1),
      transfer_operation("missing-source", "missing", "also-missing", 1),
      transfer_operation("missing-destination", "source", "missing", 1),
      transfer_operation("stale-source", "source", "destination", 0, 99, 99),
      transfer_operation("stale-destination", "source", "destination", 0, 1, 99),
      transfer_operation("same-group", "source", "source", 1, 1, 1),
      transfer_operation("different-guest", "source", "other-guest", 1, 1, 1),
      transfer_operation("invalid-amount", "source", "destination", 0, 1, 1),
      transfer_operation("not-held", "source", "destination", 1, 1, 1)
    ]

    %{"results" => results} = post_batch(conn, operations)

    assert Enum.at(results, 3) |> Map.take(["code", "group_id"]) == %{
             "code" => "group_not_found",
             "group_id" => "missing"
           }

    assert Enum.at(results, 4) |> Map.take(["code", "group_id"]) == %{
             "code" => "group_not_found",
             "group_id" => "missing"
           }

    assert Enum.at(results, 5) |> Map.take(["code", "group_id", "expected_revision"]) == %{
             "code" => "stale_revision",
             "group_id" => "source",
             "expected_revision" => 99
           }

    assert Enum.at(results, 6) |> Map.take(["code", "group_id", "expected_revision"]) == %{
             "code" => "stale_revision",
             "group_id" => "destination",
             "expected_revision" => 99
           }

    assert Enum.at(results, 7)["code"] == "invalid_transfer"
    assert Enum.at(results, 8)["code"] == "invalid_transfer"
    assert Enum.at(results, 9)["code"] == "invalid_amount"
    assert Enum.at(results, 10)["code"] == "transfer_exceeds_held_funding"
    assert get_group("source")["revision"] == 1
    assert get_group("destination")["revision"] == 1
  end

  test "inactive groups and destination capacity return the transfer-specific errors", %{
    conn: conn
  } do
    operations = [
      open_operation("source", "guest", 1),
      open_operation("destination", "guest", 1),
      payment_operation("source-pay", "source", 100, 1),
      payment_operation("destination-pay", "destination", 100, 1),
      transfer_operation("destination-full", "source", "destination", 1, 2, 2),
      cancel_operation("cancel-destination", "destination", 2, "cash"),
      transfer_operation("destination-inactive", "source", "destination", 1, 2, 3),
      cancel_operation("cancel-source", "source", 2, "cash"),
      transfer_operation("source-inactive", "source", "destination", 1, 3, 3)
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.at(results, 4)["code"] == "transfer_exceeds_outstanding"

    assert Enum.at(results, 6) |> Map.take(["code", "group_id"]) == %{
             "code" => "group_not_active",
             "group_id" => "destination"
           }

    assert Enum.at(results, 8) |> Map.take(["code", "group_id"]) == %{
             "code" => "group_not_active",
             "group_id" => "source"
           }
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp get_group(group_id) do
    build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_payment(operation_id) do
    build_conn()
    |> get("/api/v1/payments/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_credit(guest_id) do
    build_conn()
    |> get("/api/v1/guests/#{guest_id}/credit?on=2026-10-06")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_ledger do
    build_conn()
    |> get("/api/v1/ledger?on=2026-10-06")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp room_funding(group_id) do
    get_group(group_id)["rooms"]
    |> Enum.map(&Map.take(&1, ["cash_paid_cents", "credit_paid_cents"]))
  end

  defp ledger_fields do
    ~w(cash_held_cents cash_refunded_cents cash_retained_cents
       cash_converted_to_credit_cents cash_reduced_cents cash_charged_back_cents
       credit_liability_cents credit_shortfall_cents)
  end

  defp open_operation(group_id, guest_id, room_count) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "hotel-#{group_id}",
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-21",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.map(Enum.take(~w(a b c), room_count), fn room_id ->
          %{"room_id" => room_id, "nightly_rate_cents" => 500}
        end)
    }
  end

  defp payment_operation(operation_id, group_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp credit_operation(operation_id, group_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp cancel_operation(operation_id, group_id, revision, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2026-10-06",
      "group_id" => group_id,
      "refund_method" => refund_method,
      "expected_revision" => revision
    }
  end

  defp transfer_operation(
         operation_id,
         source_group_id,
         destination_group_id,
         amount,
         source_revision \\ nil,
         destination_revision \\ nil
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-05",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount
    }
    |> maybe_put("expected_revision", source_revision)
    |> maybe_put("destination_expected_revision", destination_revision)
  end

  defp reduce_operation(operation_id, payment_operation_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-05",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp chargeback_operation(operation_id, payment_operation_id, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-06",
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => revision
    }
  end

  defp maybe_put(operation, _key, nil), do: operation
  defp maybe_put(operation, key, value), do: Map.put(operation, key, value)
end
