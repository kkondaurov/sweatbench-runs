defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-01-01",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "property-1",
        "arrival_on" => "2026-02-10",
        "departure_on" => "2026-02-11",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
        ]
      },
      overrides
    )
  end

  test "moves mixed funding in reverse source order and destination room order", %{conn: conn} do
    operations = [
      open("credit-source", %{
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      }),
      %{
        "operation_id" => "credit-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "credit-source",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "credit-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("transfer-source"),
      %{
        "operation_id" => "source-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-04",
        "group_id" => "transfer-source",
        "amount_cents" => 2_000
      },
      %{
        "operation_id" => "source-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-04",
        "group_id" => "transfer-source",
        "amount_cents" => 1_000
      },
      open("transfer-destination"),
      %{
        "operation_id" => "transfer-1",
        "type" => "transfer_deposit",
        "source_group_id" => "transfer-source",
        "destination_group_id" => "transfer-destination",
        "amount_cents" => 2_500,
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)

    assert List.last(results) == %{
             "operation_id" => "transfer-1",
             "status" => "applied",
             "source_group_id" => "transfer-source",
             "destination_group_id" => "transfer-destination",
             "amount_cents" => 2_500,
             "source_outstanding_deposit_cents" => 3_500,
             "destination_outstanding_deposit_cents" => 1_500,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 500, "credit_paid_cents" => 0},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
               ],
               "revision" => 4,
               "deposit_paid_cents" => 500,
               "outstanding_deposit_cents" => 3_500
             }
           } = json_response(get(conn, "/api/v1/groups/transfer-source"), 200)

    assert %{
             "data" => %{
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "cash_paid_cents" => 1_000,
                   "credit_paid_cents" => 1_000
                 },
                 %{"room_id" => "room-b", "cash_paid_cents" => 500, "credit_paid_cents" => 0}
               ],
               "revision" => 2,
               "deposit_paid_cents" => 2_500,
               "outstanding_deposit_cents" => 1_500
             }
           } = json_response(get(conn, "/api/v1/groups/transfer-destination"), 200)

    assert %{"data" => ledger_before} =
             json_response(get(conn, "/api/v1/ledger?on=2026-01-04"), 200)

    assert ledger_before["cash_held_cents"] == 2_000
    assert ledger_before["credit_liability_cents"] == 1_100

    assert %{"data" => payment} =
             json_response(get(conn, "/api/v1/payments/source-payment"), 200)

    assert payment["held_cents"] == 2_000

    assert payment["held_by_group"] == [
             %{"group_id" => "transfer-destination", "amount_cents" => 1_500},
             %{"group_id" => "transfer-source", "amount_cents" => 500}
           ]

    assert %{"results" => [%{"status" => "applied"}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "cancel-transfer-destination",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-01-05",
                   "group_id" => "transfer-destination"
                 }
               ]),
               200
             )

    assert %{"data" => %{"available_cents" => 1_100}} =
             json_response(get(conn, "/api/v1/guests/guest-1/credit?on=2026-01-05"), 200)
  end

  test "checks both revisions before transfer rules and includes group identity in errors", %{
    conn: conn
  } do
    assert %{"results" => [_, _, %{"revision" => 2}, _]} =
             json_response(
               submit(conn, [
                 open("revision-source", %{
                   "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
                 }),
                 open("revision-destination", %{
                   "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
                 }),
                 %{
                   "operation_id" => "revision-payment",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-01-02",
                   "group_id" => "revision-source",
                   "amount_cents" => 1_000
                 },
                 %{
                   "operation_id" => "revision-transfer",
                   "type" => "transfer_deposit",
                   "source_group_id" => "revision-source",
                   "destination_group_id" => "revision-destination",
                   "amount_cents" => 0,
                   "expected_revision" => 1,
                   "destination_expected_revision" => 0
                 }
               ]),
               200
             )

    assert %{"results" => [%{"code" => "stale_revision"}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "destination-stale",
                   "type" => "transfer_deposit",
                   "source_group_id" => "revision-source",
                   "destination_group_id" => "revision-destination",
                   "amount_cents" => 0,
                   "expected_revision" => 2,
                   "destination_expected_revision" => 0
                 }
               ]),
               200
             )

    assert %{"results" => [result]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "missing-destination",
                   "type" => "transfer_deposit",
                   "source_group_id" => "revision-source",
                   "destination_group_id" => "missing",
                   "amount_cents" => 1
                 }
               ]),
               200
             )

    assert result == %{
             "operation_id" => "missing-destination",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "missing"
           }
  end

  test "reductions and chargebacks follow transferred cash across groups", %{conn: conn} do
    operations = [
      open("correction-source", %{
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      }),
      open("correction-destination", %{
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      }),
      %{
        "operation_id" => "correction-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "correction-source",
        "amount_cents" => 2_000
      },
      %{
        "operation_id" => "correction-transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "correction-source",
        "destination_group_id" => "correction-destination",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "correction-reduction",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "correction-payment",
        "amount_cents" => 500,
        "expected_revision" => 3
      },
      %{
        "operation_id" => "correction-chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "correction-payment",
        "expected_revision" => 4
      }
    ]

    assert %{"results" => [_, _, _, transfer, reduction, chargeback]} =
             json_response(submit(conn, operations), 200)

    assert transfer["source_revision"] == 3
    assert transfer["destination_revision"] == 2
    assert reduction["revision"] == 4
    assert chargeback["revision"] == 5
    assert chargeback["charged_back_cents"] == 1_500

    assert %{"data" => %{"revision" => 5, "status" => "active"}} =
             json_response(get(conn, "/api/v1/groups/correction-source"), 200)

    assert %{"data" => %{"revision" => 4, "deposit_paid_cents" => 0}} =
             json_response(get(conn, "/api/v1/groups/correction-destination"), 200)

    assert %{"data" => payment} =
             json_response(get(conn, "/api/v1/payments/correction-payment"), 200)

    assert payment == %{
             "payment_operation_id" => "correction-payment",
             "original_group_id" => "correction-source",
             "recorded_cents" => 2_000,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 500,
             "charged_back_cents" => 1_500,
             "held_by_group" => []
           }
  end

  test "settles transferred cash using the destination policy without a second transfer", %{
    conn: conn
  } do
    transfer = %{
      "operation_id" => "settlement-transfer",
      "type" => "transfer_deposit",
      "source_group_id" => "settlement-source",
      "destination_group_id" => "settlement-destination",
      "amount_cents" => 1_000
    }

    assert %{"results" => [_, _, _, transfer_result]} =
             json_response(
               submit(conn, [
                 open("settlement-source", %{
                   "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
                 }),
                 open("settlement-destination", %{
                   "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
                 }),
                 %{
                   "operation_id" => "settlement-payment",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-01-02",
                   "group_id" => "settlement-source",
                   "amount_cents" => 1_000
                 },
                 transfer
               ]),
               200
             )

    assert transfer_result["source_revision"] == 3
    assert transfer_result["destination_revision"] == 2

    assert %{"results" => [replayed]} = json_response(submit(conn, [transfer]), 200)
    assert replayed == transfer_result

    assert %{"results" => [%{"credit_issued_cents" => 1_100}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "settlement-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-01-05",
                   "group_id" => "settlement-destination",
                   "refund_method" => "hotel_credit"
                 }
               ]),
               200
             )

    assert %{"data" => payment} =
             json_response(get(conn, "/api/v1/payments/settlement-payment"), 200)

    assert payment["converted_to_credit_cents"] == 1_000
    assert payment["held_by_group"] == []

    assert %{"data" => ledger} = json_response(get(conn, "/api/v1/ledger?on=2026-01-05"), 200)
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_converted_to_credit_cents"] == 1_000
    assert ledger["credit_liability_cents"] == 1_100
  end
end
