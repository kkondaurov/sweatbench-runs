defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_operation(group_id, guest_id, rooms, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-#{group_id}",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: group_id,
        guest_id: guest_id,
        property_id: "property-#{group_id}",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-11",
        rate_plan: "flexible",
        rooms: rooms
      },
      overrides
    )
  end

  test "transfers mixed funding in reverse creation order and reports transferred payments", %{
    conn: conn
  } do
    transfer = %{
      operation_id: "transfer-mixed-funding",
      type: "transfer_deposit",
      source_group_id: "transfer-source",
      destination_group_id: "transfer-destination",
      amount_cents: 70,
      expected_revision: 3,
      destination_expected_revision: 1
    }

    results =
      post_batch(conn, [
        open_operation("credit-origin", "shared-guest", [
          %{room_id: "credit-origin-room", nightly_rate_cents: 200}
        ]),
        %{
          operation_id: "credit-origin-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "credit-origin",
          amount_cents: 40
        },
        %{
          operation_id: "credit-origin-cancel",
          type: "cancel_group",
          occurred_on: "2026-10-05",
          group_id: "credit-origin",
          refund_method: "hotel_credit"
        },
        open_operation("transfer-source", "shared-guest", [
          %{room_id: "source-room", nightly_rate_cents: 500}
        ]),
        %{
          operation_id: "transfer-source-cash",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "transfer-source",
          amount_cents: 60
        },
        %{
          operation_id: "transfer-source-credit",
          type: "apply_hotel_credit",
          occurred_on: "2026-10-06",
          group_id: "transfer-source",
          amount_cents: 40
        },
        open_operation("transfer-destination", "shared-guest", [
          %{room_id: "destination-room-a", nightly_rate_cents: 250},
          %{room_id: "destination-room-b", nightly_rate_cents: 250}
        ]),
        transfer,
        transfer,
        %{
          operation_id: "destination-follow-up-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-07",
          group_id: "transfer-destination",
          amount_cents: 10,
          expected_revision: 2
        }
      ])

    expected_transfer = %{
      "operation_id" => "transfer-mixed-funding",
      "status" => "applied",
      "source_group_id" => "transfer-source",
      "destination_group_id" => "transfer-destination",
      "amount_cents" => 70,
      "source_outstanding_deposit_cents" => 70,
      "destination_outstanding_deposit_cents" => 30,
      "source_revision" => 4,
      "destination_revision" => 2
    }

    assert Enum.at(results, 7) == expected_transfer
    assert Enum.at(results, 8) == expected_transfer

    assert Enum.at(results, 9) == %{
             "operation_id" => "destination-follow-up-payment",
             "status" => "applied",
             "group_id" => "transfer-destination",
             "amount_cents" => 10,
             "outstanding_deposit_cents" => 20,
             "revision" => 3
           }

    source =
      conn
      |> get("/api/v1/groups/transfer-source")
      |> json_response(200)
      |> Map.fetch!("data")

    assert source["revision"] == 4
    assert source["cash_paid_cents"] == 30
    assert source["credit_paid_cents"] == 0
    assert source["outstanding_deposit_cents"] == 70

    destination =
      conn
      |> get("/api/v1/groups/transfer-destination")
      |> json_response(200)
      |> Map.fetch!("data")

    assert destination["revision"] == 3
    assert destination["cash_paid_cents"] == 40
    assert destination["credit_paid_cents"] == 40
    assert destination["outstanding_deposit_cents"] == 20

    assert destination["rooms"] == [
             %{
               "room_id" => "destination-room-a",
               "nightly_rate_cents" => 250,
               "status" => "active",
               "deposit_due_cents" => 50,
               "cash_paid_cents" => 10,
               "credit_paid_cents" => 40
             },
             %{
               "room_id" => "destination-room-b",
               "nightly_rate_cents" => 250,
               "status" => "active",
               "deposit_due_cents" => 50,
               "cash_paid_cents" => 30,
               "credit_paid_cents" => 0
             }
           ]

    assert conn
           |> get("/api/v1/payments/transfer-source-cash")
           |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "transfer-source-cash",
               "original_group_id" => "transfer-source",
               "recorded_cents" => 60,
               "held_cents" => 60,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "transfer-destination", "amount_cents" => 30},
                 %{"group_id" => "transfer-source", "amount_cents" => 30}
               ]
             }
           }

    ledger =
      conn
      |> get("/api/v1/ledger?on=2026-10-06")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["cash_held_cents"] == 70
    assert ledger["cash_converted_to_credit_cents"] == 40
    assert ledger["credit_liability_cents"] == 44

    assert post_batch(conn, [
             %{
               operation_id: "cancel-after-transfer",
               type: "cancel_group",
               occurred_on: "2026-10-07",
               group_id: "transfer-destination"
             }
           ]) == [
             %{
               "operation_id" => "cancel-after-transfer",
               "status" => "applied",
               "group_id" => "transfer-destination",
               "refunded_cents" => 40,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }
           ]

    assert conn
           |> get("/api/v1/guests/shared-guest/credit?on=2026-10-07")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 44

    assert conn
           |> get("/api/v1/payments/transfer-source-cash")
           |> json_response(200)
           |> Map.fetch!("data") == %{
             "payment_operation_id" => "transfer-source-cash",
             "original_group_id" => "transfer-source",
             "recorded_cents" => 60,
             "held_cents" => 30,
             "refunded_cents" => 30,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0,
             "held_by_group" => [
               %{"group_id" => "transfer-source", "amount_cents" => 30}
             ]
           }
  end

  test "reductions and chargebacks follow transferred cash across groups", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation("reversal-source", "reversal-guest", [
          %{room_id: "source-room", nightly_rate_cents: 1000}
        ]),
        open_operation("reversal-destination", "reversal-guest", [
          %{room_id: "destination-room", nightly_rate_cents: 500}
        ]),
        %{
          operation_id: "reversal-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "reversal-source",
          amount_cents: 100
        },
        %{
          operation_id: "reversal-transfer",
          type: "transfer_deposit",
          source_group_id: "reversal-source",
          destination_group_id: "reversal-destination",
          amount_cents: 60,
          expected_revision: 2,
          destination_expected_revision: 1
        },
        %{
          operation_id: "reversal-reduction",
          type: "reduce_cash_payment",
          payment_operation_id: "reversal-payment",
          amount_cents: 50,
          expected_revision: 3
        },
        %{
          operation_id: "reversal-chargeback",
          type: "charge_back_payment",
          payment_operation_id: "reversal-payment",
          expected_revision: 4
        }
      ])

    assert Enum.at(results, 4) == %{
             "operation_id" => "reversal-reduction",
             "status" => "applied",
             "payment_operation_id" => "reversal-payment",
             "group_id" => "reversal-source",
             "amount_cents" => 50,
             "outstanding_deposit_cents" => 160,
             "revision" => 4
           }

    assert Enum.at(results, 5) == %{
             "operation_id" => "reversal-chargeback",
             "status" => "applied",
             "payment_operation_id" => "reversal-payment",
             "group_id" => "reversal-source",
             "charged_back_cents" => 50,
             "outstanding_deposit_cents" => 200,
             "revision" => 5
           }

    for {group_id, expected_revision, due} <- [
          {"reversal-source", 5, 200},
          {"reversal-destination", 4, 100}
        ] do
      group =
        conn
        |> get("/api/v1/groups/#{group_id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert group["revision"] == expected_revision
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == due
    end

    assert conn
           |> get("/api/v1/payments/reversal-payment")
           |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "reversal-payment",
               "original_group_id" => "reversal-source",
               "recorded_cents" => 100,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 50,
               "charged_back_cents" => 50,
               "held_by_group" => []
             }
           }

    ledger =
      conn
      |> get("/api/v1/ledger")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_reduced_cents"] == 50
    assert ledger["cash_charged_back_cents"] == 50
  end

  test "resolves both groups and checks revisions before transfer validation", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation("transfer-guard-source", "guest-a", [
          %{room_id: "source-room", nightly_rate_cents: 100}
        ]),
        open_operation("transfer-guard-destination", "guest-b", [
          %{room_id: "destination-room", nightly_rate_cents: 100}
        ]),
        %{
          operation_id: "transfer-guard-rejected",
          type: "transfer_deposit",
          source_group_id: "transfer-guard-source",
          destination_group_id: "transfer-guard-destination",
          amount_cents: 0,
          expected_revision: 1,
          destination_expected_revision: 0
        },
        %{
          operation_id: "transfer-guest-mismatch",
          type: "transfer_deposit",
          source_group_id: "transfer-guard-source",
          destination_group_id: "transfer-guard-destination",
          amount_cents: 0,
          expected_revision: 1,
          destination_expected_revision: 1
        }
      ])

    assert Enum.at(results, 2) == %{
             "operation_id" => "transfer-guard-rejected",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "transfer-guard-destination",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    assert Enum.at(results, 3) == %{
             "operation_id" => "transfer-guest-mismatch",
             "status" => "rejected",
             "code" => "invalid_transfer"
           }

    assert conn
           |> get("/api/v1/groups/transfer-guard-source")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 1
  end

  test "rejects transfers that exceed held funding or destination deposit", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation("limits-source", "limits-guest", [
          %{room_id: "source-room", nightly_rate_cents: 1000}
        ]),
        open_operation("limits-destination", "limits-guest", [
          %{room_id: "destination-room", nightly_rate_cents: 50}
        ]),
        %{
          operation_id: "limits-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "limits-source",
          amount_cents: 20
        },
        %{
          operation_id: "too-much-held",
          type: "transfer_deposit",
          source_group_id: "limits-source",
          destination_group_id: "limits-destination",
          amount_cents: 21,
          expected_revision: 2,
          destination_expected_revision: 1
        },
        %{
          operation_id: "too-much-due",
          type: "transfer_deposit",
          source_group_id: "limits-source",
          destination_group_id: "limits-destination",
          amount_cents: 11,
          expected_revision: 2,
          destination_expected_revision: 1
        },
        %{
          operation_id: "zero-transfer",
          type: "transfer_deposit",
          source_group_id: "limits-source",
          destination_group_id: "limits-destination",
          amount_cents: 0,
          expected_revision: 2,
          destination_expected_revision: 1
        }
      ])

    assert Enum.map(Enum.drop(results, 3), & &1["code"]) == [
             "transfer_exceeds_held_funding",
             "transfer_exceeds_outstanding",
             "invalid_amount"
           ]

    assert conn
           |> get("/api/v1/groups/limits-source")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2

    assert conn
           |> get("/api/v1/groups/limits-destination")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 1
  end
end
