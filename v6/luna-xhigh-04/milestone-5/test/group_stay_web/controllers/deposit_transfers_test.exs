defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(operation_id, overrides) do
    Map.merge(
      %{
        operation_id: operation_id,
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: "group-81",
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: "2027-03-20",
        departure_on: "2027-03-22",
        rate_plan: "flexible",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 22500}]
      },
      overrides
    )
  end

  test "moves mixed held funding in reverse source order and preserves provenance", %{conn: conn} do
    assert post_batch(conn, [
             open_operation("credit-open", %{group_id: "credit-source"}),
             %{
               operation_id: "credit-payment",
               type: "record_cash_payment",
               occurred_on: "2026-10-04",
               group_id: "credit-source",
               amount_cents: 9000
             },
             %{
               operation_id: "credit-cancel",
               type: "cancel_group",
               occurred_on: "2026-10-01",
               group_id: "credit-source",
               refund_method: "hotel_credit"
             },
             open_operation("source-open", %{
               group_id: "source",
               rooms: [
                 %{room_id: "source-a", nightly_rate_cents: 22500},
                 %{room_id: "source-b", nightly_rate_cents: 22500}
               ]
             }),
             open_operation("destination-open", %{group_id: "destination"})
           ])
           |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "source-payment",
               type: "record_cash_payment",
               occurred_on: "2026-10-04",
               group_id: "source",
               amount_cents: 10000
             },
             %{
               operation_id: "source-credit",
               type: "apply_hotel_credit",
               occurred_on: "2026-10-05",
               group_id: "source",
               amount_cents: 8000
             }
           ])
           |> json_response(200)

    transfer = %{
      operation_id: "transfer",
      type: "transfer_deposit",
      occurred_on: "2026-10-06",
      source_group_id: "source",
      destination_group_id: "destination",
      amount_cents: 9000,
      expected_revision: 3,
      destination_expected_revision: 1
    }

    result =
      post_batch(conn, [transfer])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result == %{
             "operation_id" => "transfer",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 9000,
             "source_outstanding_deposit_cents" => 9000,
             "destination_outstanding_deposit_cents" => 0,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    source =
      get(build_conn(), "/api/v1/groups/source")
      |> json_response(200)
      |> get_in(["data"])

    assert source["rooms"] == [
             %{
               "room_id" => "source-a",
               "nightly_rate_cents" => 22500,
               "status" => "active",
               "deposit_due_cents" => 9000,
               "cash_paid_cents" => 9000,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "source-b",
               "nightly_rate_cents" => 22500,
               "status" => "active",
               "deposit_due_cents" => 9000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
           ]

    assert get(build_conn(), "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "rooms"]) == [
             %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 22500,
               "status" => "active",
               "deposit_due_cents" => 9000,
               "cash_paid_cents" => 1000,
               "credit_paid_cents" => 8000
             }
           ]

    payment =
      get(build_conn(), "/api/v1/payments/source-payment")
      |> json_response(200)
      |> get_in(["data"])

    assert payment["held_cents"] == 10000

    assert payment["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 1000},
             %{"group_id" => "source", "amount_cents" => 9000}
           ]

    ledger_before_retry = get(build_conn(), "/api/v1/ledger") |> json_response(200)

    assert post_batch(conn, [transfer])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == result

    assert get(build_conn(), "/api/v1/groups/source")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 4

    assert get(build_conn(), "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2

    assert get(build_conn(), "/api/v1/ledger") |> json_response(200) == ledger_before_retry

    assert post_batch(conn, [
             %{
               operation_id: "destination-cancel",
               type: "cancel_group",
               occurred_on: "2026-10-07",
               group_id: "destination"
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == %{
             "operation_id" => "destination-cancel",
             "status" => "applied",
             "group_id" => "destination",
             "refunded_cents" => 1000,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-10-07")
           |> json_response(200)
           |> get_in(["data"]) == %{
             "guest_id" => "guest-22",
             "available_cents" => 9900,
             "lots" => [
               %{
                 "source_operation_id" => "credit-cancel",
                 "remaining_cents" => 9900,
                 "expires_on" => "2027-10-02"
               }
             ]
           }

    assert get(build_conn(), "/api/v1/payments/source-payment")
           |> json_response(200)
           |> get_in(["data"])
           |> Map.take(["held_cents", "refunded_cents", "held_by_group"]) == %{
             "held_cents" => 9000,
             "refunded_cents" => 1000,
             "held_by_group" => [%{"group_id" => "source", "amount_cents" => 9000}]
           }
  end

  test "reductions follow transferred cash and bump every changed group", %{conn: conn} do
    assert post_batch(conn, [
             open_operation("source-open", %{group_id: "source"}),
             open_operation("destination-open", %{group_id: "destination"}),
             %{
               operation_id: "payment",
               type: "record_cash_payment",
               occurred_on: "2026-10-04",
               group_id: "source",
               amount_cents: 5000
             },
             %{
               operation_id: "transfer",
               type: "transfer_deposit",
               occurred_on: "2026-10-05",
               source_group_id: "source",
               destination_group_id: "destination",
               amount_cents: 2000,
               expected_revision: 2,
               destination_expected_revision: 1
             }
           ])
           |> json_response(200)

    reduction =
      post_batch(conn, [
        %{
          operation_id: "reduction",
          type: "reduce_cash_payment",
          occurred_on: "2026-10-06",
          payment_operation_id: "payment",
          amount_cents: 2000,
          expected_revision: 3
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert reduction == %{
             "operation_id" => "reduction",
             "status" => "applied",
             "payment_operation_id" => "payment",
             "group_id" => "source",
             "amount_cents" => 2000,
             "outstanding_deposit_cents" => 6000,
             "revision" => 4
           }

    assert get(build_conn(), "/api/v1/groups/source")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 4

    assert get(build_conn(), "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data"])
           |> Map.take(["revision", "deposit_paid_cents", "outstanding_deposit_cents"]) ==
             %{"revision" => 3, "deposit_paid_cents" => 0, "outstanding_deposit_cents" => 9000}

    assert get(build_conn(), "/api/v1/payments/payment")
           |> json_response(200)
           |> get_in(["data"])
           |> Map.take(["held_cents", "reduced_cents", "held_by_group"]) == %{
             "held_cents" => 3000,
             "reduced_cents" => 2000,
             "held_by_group" => [%{"group_id" => "source", "amount_cents" => 3000}]
           }
  end

  test "resolves both groups before revisions and reports transfer validation errors", %{
    conn: conn
  } do
    assert post_batch(conn, [
             open_operation("source-open", %{group_id: "source"}),
             open_operation("destination-open", %{group_id: "destination"})
           ])
           |> json_response(200)

    missing_source = %{
      operation_id: "missing-source",
      type: "transfer_deposit",
      occurred_on: "2026-10-04",
      source_group_id: "missing",
      destination_group_id: "destination",
      amount_cents: 1
    }

    assert post_batch(conn, [missing_source])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == %{
             "operation_id" => "missing-source",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "missing"
           }

    missing_destination = %{
      operation_id: "missing-destination",
      type: "transfer_deposit",
      occurred_on: "2026-10-04",
      source_group_id: "source",
      destination_group_id: "missing",
      amount_cents: 1
    }

    assert post_batch(conn, [missing_destination])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == %{
             "operation_id" => "missing-destination",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "missing"
           }

    stale_destination = %{
      operation_id: "stale-destination",
      type: "transfer_deposit",
      occurred_on: "2026-10-04",
      source_group_id: "source",
      destination_group_id: "destination",
      amount_cents: -1,
      expected_revision: 1,
      destination_expected_revision: 0
    }

    assert post_batch(conn, [stale_destination])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == %{
             "operation_id" => "stale-destination",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "destination",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    invalid_transfer = %{
      operation_id: "invalid-transfer",
      type: "transfer_deposit",
      occurred_on: "2026-10-04",
      source_group_id: "source",
      destination_group_id: "source",
      amount_cents: 1,
      expected_revision: 1,
      destination_expected_revision: 1
    }

    assert post_batch(conn, [invalid_transfer])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == %{
             "operation_id" => "invalid-transfer",
             "status" => "rejected",
             "code" => "invalid_transfer"
           }

    assert post_batch(conn, [
             %{
               operation_id: "no-funding",
               type: "transfer_deposit",
               occurred_on: "2026-10-04",
               source_group_id: "source",
               destination_group_id: "destination",
               amount_cents: 1
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == %{
             "operation_id" => "no-funding",
             "status" => "rejected",
             "code" => "transfer_exceeds_held_funding"
           }
  end

  test "chargebacks follow transferred cash without revising credit-funded groups", %{conn: conn} do
    assert post_batch(conn, [
             open_operation("source-open", %{group_id: "source"}),
             open_operation("destination-open", %{group_id: "destination"}),
             %{
               operation_id: "payment",
               type: "record_cash_payment",
               occurred_on: "2026-10-04",
               group_id: "source",
               amount_cents: 5000
             },
             %{
               operation_id: "transfer",
               type: "transfer_deposit",
               occurred_on: "2026-10-05",
               source_group_id: "source",
               destination_group_id: "destination",
               amount_cents: 2000
             }
           ])
           |> json_response(200)

    chargeback =
      post_batch(conn, [
        %{
          operation_id: "chargeback",
          type: "charge_back_payment",
          occurred_on: "2026-10-06",
          payment_operation_id: "payment",
          expected_revision: 3
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert chargeback == %{
             "operation_id" => "chargeback",
             "status" => "applied",
             "payment_operation_id" => "payment",
             "group_id" => "source",
             "charged_back_cents" => 5000,
             "outstanding_deposit_cents" => 9000,
             "revision" => 4
           }

    assert get(build_conn(), "/api/v1/groups/source")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 4

    assert get(build_conn(), "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data"])
           |> Map.take(["revision", "deposit_paid_cents", "outstanding_deposit_cents"]) ==
             %{"revision" => 3, "deposit_paid_cents" => 0, "outstanding_deposit_cents" => 9000}

    assert get(build_conn(), "/api/v1/payments/payment")
           |> json_response(200)
           |> get_in(["data"])
           |> Map.take(["held_cents", "charged_back_cents", "held_by_group"]) == %{
             "held_cents" => 0,
             "charged_back_cents" => 5000,
             "held_by_group" => []
           }
  end
end
