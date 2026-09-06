defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-#{group_id}",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: group_id,
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-11",
        rate_plan: "flexible",
        rooms: [
          %{room_id: "#{group_id}-room-a", nightly_rate_cents: 10_000},
          %{room_id: "#{group_id}-room-b", nightly_rate_cents: 10_000}
        ]
      },
      overrides
    )
  end

  test "moves held cash in reverse allocation order and is visible in a same-batch transfer", %{
    conn: conn
  } do
    response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          open_operation("transfer-source"),
          open_operation("transfer-destination"),
          %{
            operation_id: "transfer-payment",
            type: "record_cash_payment",
            occurred_on: "2026-10-04",
            group_id: "transfer-source",
            amount_cents: 3_000,
            expected_revision: 1
          },
          %{
            operation_id: "transfer-cash",
            type: "transfer_deposit",
            source_group_id: "transfer-source",
            destination_group_id: "transfer-destination",
            amount_cents: 2_500,
            expected_revision: 2,
            destination_expected_revision: 1
          }
        ]
      })
      |> json_response(200)

    assert List.last(response["results"]) == %{
             "operation_id" => "transfer-cash",
             "status" => "applied",
             "source_group_id" => "transfer-source",
             "destination_group_id" => "transfer-destination",
             "amount_cents" => 2_500,
             "source_outstanding_deposit_cents" => 3_500,
             "destination_outstanding_deposit_cents" => 1_500,
             "source_revision" => 3,
             "destination_revision" => 2
           }

    assert %{
             "revision" => 3,
             "cash_paid_cents" => 500,
             "outstanding_deposit_cents" => 3_500,
             "rooms" => [
               %{"cash_paid_cents" => 500},
               %{"cash_paid_cents" => 0}
             ]
           } = group(conn, "transfer-source")

    assert %{
             "revision" => 2,
             "cash_paid_cents" => 2_500,
             "outstanding_deposit_cents" => 1_500,
             "rooms" => [
               %{"cash_paid_cents" => 2_000},
               %{"cash_paid_cents" => 500}
             ]
           } = group(conn, "transfer-destination")

    assert %{
             "cash_held_cents" => 3_000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0
           } = ledger(conn)

    assert %{
             "held_cents" => 3_000,
             "held_by_group" => [
               %{"group_id" => "transfer-destination", "amount_cents" => 2_500},
               %{"group_id" => "transfer-source", "amount_cents" => 500}
             ]
           } = payment(conn, "transfer-payment")

    retry =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "transfer-cash",
            type: "transfer_deposit",
            source_group_id: "transfer-source",
            destination_group_id: "transfer-destination",
            amount_cents: 2_500,
            expected_revision: 2,
            destination_expected_revision: 1
          }
        ]
      })
      |> json_response(200)

    assert retry["results"] == [List.last(response["results"])]
    assert group(conn, "transfer-source")["revision"] == 3
    assert group(conn, "transfer-destination")["revision"] == 2
  end

  test "reductions and chargebacks follow transferred cash across groups", %{conn: conn} do
    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        open_operation("correction-source"),
        open_operation("correction-destination"),
        %{
          operation_id: "correction-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "correction-source",
          amount_cents: 3_000
        },
        %{
          operation_id: "correction-transfer",
          type: "transfer_deposit",
          source_group_id: "correction-source",
          destination_group_id: "correction-destination",
          amount_cents: 2_500,
          expected_revision: 2,
          destination_expected_revision: 1
        }
      ]
    })
    |> json_response(200)

    reduction =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "correction-reduction",
            type: "reduce_cash_payment",
            payment_operation_id: "correction-payment",
            amount_cents: 1_000,
            expected_revision: 3
          }
        ]
      })
      |> json_response(200)

    assert hd(reduction["results"]) == %{
             "operation_id" => "correction-reduction",
             "status" => "applied",
             "payment_operation_id" => "correction-payment",
             "group_id" => "correction-source",
             "amount_cents" => 1_000,
             "outstanding_deposit_cents" => 3_500,
             "revision" => 4
           }

    assert group(conn, "correction-source")["revision"] == 4
    assert group(conn, "correction-destination")["revision"] == 3

    assert payment(conn, "correction-payment")["held_by_group"] == [
             %{"group_id" => "correction-destination", "amount_cents" => 1_500},
             %{"group_id" => "correction-source", "amount_cents" => 500}
           ]

    chargeback =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "correction-chargeback",
            type: "charge_back_payment",
            payment_operation_id: "correction-payment",
            expected_revision: 4
          }
        ]
      })
      |> json_response(200)

    assert hd(chargeback["results"]) == %{
             "operation_id" => "correction-chargeback",
             "status" => "applied",
             "payment_operation_id" => "correction-payment",
             "group_id" => "correction-source",
             "charged_back_cents" => 2_000,
             "outstanding_deposit_cents" => 4_000,
             "revision" => 5
           }

    assert group(conn, "correction-source")["revision"] == 5
    assert group(conn, "correction-destination")["revision"] == 4
    assert payment(conn, "correction-payment")["held_by_group"] == []

    assert %{
             "cash_held_cents" => 0,
             "cash_reduced_cents" => 1_000,
             "cash_charged_back_cents" => 2_000
           } = ledger(conn)
  end

  test "transferred credit keeps its lot and restores it without a second bonus", %{conn: conn} do
    issuer =
      open_operation("credit-issuer", %{
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21",
        rooms: [%{room_id: "issuer-room", nightly_rate_cents: 10_000}]
      })

    source =
      open_operation("credit-transfer-source", %{
        arrival_on: "2027-02-01",
        departure_on: "2027-02-02"
      })

    destination =
      open_operation("credit-transfer-destination", %{
        arrival_on: "2027-02-01",
        departure_on: "2027-02-02"
      })

    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        issuer,
        %{
          operation_id: "credit-issuer-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "credit-issuer",
          amount_cents: 2_000
        },
        %{
          operation_id: "credit-issuer-cancel",
          type: "cancel_group",
          occurred_on: "2026-12-01",
          group_id: "credit-issuer",
          refund_method: "hotel_credit"
        },
        source,
        destination,
        %{
          operation_id: "credit-apply-source",
          type: "apply_hotel_credit",
          occurred_on: "2026-12-02",
          group_id: "credit-transfer-source",
          amount_cents: 1_500
        },
        %{
          operation_id: "credit-transfer",
          type: "transfer_deposit",
          source_group_id: "credit-transfer-source",
          destination_group_id: "credit-transfer-destination",
          amount_cents: 1_000,
          expected_revision: 2,
          destination_expected_revision: 1
        }
      ]
    })
    |> json_response(200)

    assert %{"credit_paid_cents" => 500, "revision" => 3} =
             group(conn, "credit-transfer-source")

    assert %{"credit_paid_cents" => 1_000, "revision" => 2} =
             group(conn, "credit-transfer-destination")

    assert %{"available_cents" => 700} = credit(conn, "guest-22", "2026-12-02")

    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        %{
          operation_id: "credit-cancel-destination",
          type: "cancel_group",
          occurred_on: "2026-12-03",
          group_id: "credit-transfer-destination",
          expected_revision: 2
        }
      ]
    })
    |> json_response(200)

    assert %{"available_cents" => 1_700} = credit(conn, "guest-22", "2026-12-03")

    assert %{"credit_liability_cents" => 2_200} = ledger(conn)
  end

  test "checks both revisions before transfer validation and resolves groups in order", %{
    conn: conn
  } do
    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        open_operation("revision-source"),
        open_operation("revision-destination", %{guest_id: "guest-other"})
      ]
    })
    |> json_response(200)

    stale_source =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "stale-source-transfer",
            type: "transfer_deposit",
            source_group_id: "revision-source",
            destination_group_id: "revision-destination",
            amount_cents: -1,
            expected_revision: 0
          }
        ]
      })
      |> json_response(200)

    assert hd(stale_source["results"])["code"] == "stale_revision"
    assert hd(stale_source["results"])["group_id"] == "revision-source"

    stale_destination =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "stale-destination-transfer",
            type: "transfer_deposit",
            source_group_id: "revision-source",
            destination_group_id: "revision-destination",
            amount_cents: -1,
            expected_revision: 1,
            destination_expected_revision: 0
          }
        ]
      })
      |> json_response(200)

    assert hd(stale_destination["results"]) == %{
             "operation_id" => "stale-destination-transfer",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "revision-destination",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    invalid =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "different-guests-transfer",
            type: "transfer_deposit",
            source_group_id: "revision-source",
            destination_group_id: "revision-destination",
            amount_cents: 1
          }
        ]
      })
      |> json_response(200)

    assert hd(invalid["results"]) == %{
             "operation_id" => "different-guests-transfer",
             "status" => "rejected",
             "code" => "invalid_transfer"
           }

    missing =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "missing-transfer-source",
            type: "transfer_deposit",
            source_group_id: "missing-source",
            destination_group_id: "revision-destination",
            amount_cents: 1
          },
          %{
            operation_id: "missing-transfer-destination",
            type: "transfer_deposit",
            source_group_id: "revision-source",
            destination_group_id: "missing-destination",
            amount_cents: 1
          }
        ]
      })
      |> json_response(200)

    assert Enum.map(missing["results"], &{&1["code"], &1["group_id"]}) == [
             {"group_not_found", "missing-source"},
             {"group_not_found", "missing-destination"}
           ]
  end

  defp group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp payment(conn, payment_id) do
    conn
    |> get("/api/v1/payments/#{payment_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp credit(conn, guest_id, on) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end
end
