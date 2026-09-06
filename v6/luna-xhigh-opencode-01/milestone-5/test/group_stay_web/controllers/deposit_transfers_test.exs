defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  test "moves cash in reverse allocation order and exposes held cash by group", %{conn: conn} do
    submit(conn, [open_group("source")])
    submit(conn, [open_group("destination")])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [payment("pay-source", "source", 6_000)])

    assert %{
             "results" => [
               %{
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 2_500,
                 "source_outstanding_deposit_cents" => 2_500,
                 "destination_outstanding_deposit_cents" => 3_500,
                 "source_revision" => 3,
                 "destination_revision" => 2
               } = transfer_result
             ]
           } = submit(conn, [transfer("transfer-1", "source", "destination", 2_500)])

    assert %{"results" => [^transfer_result]} =
             submit(conn, [transfer("transfer-1", "source", "destination", 2_500)])

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 2_000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 1_500}
               ],
               "revision" => 3
             }
           } = get_group(conn, "source")

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 2_000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 500}
               ],
               "revision" => 2
             }
           } = get_group(conn, "destination")

    assert %{
             "data" => %{
               "held_cents" => 6_000,
               "held_by_group" => [
                 %{"group_id" => "destination", "amount_cents" => 2_500},
                 %{"group_id" => "source", "amount_cents" => 3_500}
               ]
             }
           } = get_payment(conn, "pay-source")
  end

  test "transfers credit without restoring its expiry and restores it from the original lot", %{
    conn: conn
  } do
    submit(conn, [open_group("credit-source")])
    submit(conn, [payment("credit-payment", "credit-source", 2_000)])

    assert %{"results" => [%{"credit_issued_cents" => 2_200}]} =
             submit(conn, [
               cancel("credit-cancel", "credit-source")
               |> Map.put("refund_method", "hotel_credit")
             ])

    submit(conn, [open_group("source")])
    submit(conn, [open_group("destination")])

    assert %{"results" => [%{"outstanding_deposit_cents" => 4_000, "revision" => 2}]} =
             submit(conn, [credit_payment("credit-apply", "source", 2_000)])

    assert %{
             "results" => [
               %{
                 "source_outstanding_deposit_cents" => 5_000,
                 "destination_outstanding_deposit_cents" => 5_000,
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ]
           } = submit(conn, [transfer("credit-transfer", "source", "destination", 1_000)])

    assert %{"data" => %{"available_cents" => 200}} = get_credit(conn, "guest-1", "2026-10-01")

    assert %{"results" => [%{"refunded_cents" => 0, "retained_cents" => 0}]} =
             submit(conn, [cancel("destination-cancel", "destination")])

    assert %{"data" => %{"available_cents" => 1_200}} =
             get_credit(conn, "guest-1", "2026-10-01")
  end

  test "takes mixed funding in allocation order and preserves each funding kind", %{conn: conn} do
    submit(conn, [open_group("credit-source")])
    submit(conn, [payment("credit-payment", "credit-source", 2_000)])

    submit(conn, [
      cancel("credit-cancel", "credit-source")
      |> Map.put("refund_method", "hotel_credit")
    ])

    submit(conn, [open_group("source")])
    submit(conn, [open_group("destination")])
    submit(conn, [payment("cash-payment", "source", 2_000)])
    submit(conn, [credit_payment("credit-apply", "source", 2_000)])

    assert %{"results" => [%{"amount_cents" => 3_000}]} =
             submit(conn, [transfer("mixed-transfer", "source", "destination", 3_000)])

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 1_000, "credit_paid_cents" => 0},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
               ]
             }
           } = get_group(conn, "source")

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 0, "credit_paid_cents" => 2_000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 1_000, "credit_paid_cents" => 0}
               ]
             }
           } = get_group(conn, "destination")
  end

  test "reductions and chargebacks update every group holding transferred cash", %{conn: conn} do
    submit(conn, [open_group("source")])
    submit(conn, [open_group("destination")])
    submit(conn, [payment("pay-source", "source", 6_000)])
    submit(conn, [transfer("transfer-1", "source", "destination", 2_000)])

    assert %{"results" => [%{"revision" => 4}]} =
             submit(conn, [reduce("reduce-1", "pay-source", 1_000)])

    assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 1_000}} =
             get_group(conn, "destination")

    assert %{"results" => [%{"charged_back_cents" => 5_000, "revision" => 5}]} =
             submit(conn, [chargeback("chargeback-1", "pay-source")])

    assert %{"data" => %{"revision" => 4, "deposit_paid_cents" => 0}} =
             get_group(conn, "destination")

    assert %{
             "data" => %{
               "recorded_cents" => 6_000,
               "held_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 5_000
             }
           } = get_payment(conn, "pay-source")
  end

  test "settles transferred cash under the destination policy", %{conn: conn} do
    submit(conn, [open_group("source")])
    submit(conn, [open_group("destination")])
    submit(conn, [payment("pay-source", "source", 6_000)])
    submit(conn, [transfer("transfer-1", "source", "destination", 2_000)])

    assert %{"results" => [%{"refunded_cents" => 2_000, "revision" => 3}]} =
             submit(conn, [cancel("destination-cancel", "destination")])

    assert %{
             "data" => %{
               "held_cents" => 4_000,
               "refunded_cents" => 2_000,
               "held_by_group" => [%{"group_id" => "source", "amount_cents" => 4_000}]
             }
           } = get_payment(conn, "pay-source")

    assert %{"data" => %{"cash_held_cents" => 4_000, "cash_refunded_cents" => 2_000}} =
             conn
             |> get("/api/v1/ledger")
             |> json_response(200)

    assert %{"results" => [%{"charged_back_cents" => 6_000, "revision" => 4}]} =
             submit(conn, [chargeback("chargeback-1", "pay-source")])

    assert %{"data" => %{"cash_held_cents" => 0, "cash_refunded_cents" => 0}} =
             conn
             |> get("/api/v1/ledger")
             |> json_response(200)
  end

  test "resolves transfer errors and revisions in the documented order", %{conn: conn} do
    operation = transfer("missing-source", "missing", "also-missing", 1)

    assert %{
             "results" => [
               %{"code" => "group_not_found", "group_id" => "missing"}
             ]
           } = submit(conn, [operation])

    submit(conn, [open_group("source")])
    submit(conn, [open_group("destination")])

    stale =
      transfer("stale", "source", "destination", 1)
      |> Map.merge(%{"expected_revision" => 0, "amount_cents" => 0})

    assert %{
             "results" => [
               %{
                 "code" => "stale_revision",
                 "group_id" => "source",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           } = submit(conn, [stale])

    assert %{"results" => [%{"code" => "transfer_exceeds_held_funding"}]} =
             submit(conn, [transfer("too-much", "source", "destination", 6_001)])
  end

  defp open_group(group_id) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => "property-1",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 20_000}
      ]
    }
  end

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp credit_payment(operation_id, group_id, amount_cents) do
    payment(operation_id, group_id, amount_cents)
    |> Map.put("type", "apply_hotel_credit")
  end

  defp transfer(operation_id, source_group_id, destination_group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id
    }
  end

  defp reduce(operation_id, payment_operation_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp chargeback(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id
    }
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp get_group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  defp get_payment(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
  end

  defp get_credit(conn, guest_id, on) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
  end
end
