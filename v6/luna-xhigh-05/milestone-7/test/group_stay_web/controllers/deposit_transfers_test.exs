defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  test "moves mixed funding, preserves provenance, and settles at the destination", %{conn: conn} do
    post_batch(conn, [
      open_operation("credit-source", [%{"room_id" => "room", "nightly_rate_cents" => 500}]),
      cash_payment("credit-source-payment", "credit-source", 100),
      cancellation("credit-source-cancel", "credit-source", "2026-10-04", "hotel_credit"),
      open_operation("source", [%{"room_id" => "source-room", "nightly_rate_cents" => 1_000}]),
      cash_payment("source-payment", "source", 100),
      %{
        "operation_id" => "source-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "source",
        "amount_cents" => 100,
        "expected_revision" => 2
      },
      open_operation("destination", [
        %{"room_id" => "first", "nightly_rate_cents" => 500},
        %{"room_id" => "second", "nightly_rate_cents" => 500}
      ])
    ])

    transfer_operation = %{
      "operation_id" => "move-deposit",
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-05",
      "source_group_id" => "source",
      "destination_group_id" => "destination",
      "amount_cents" => 150,
      "expected_revision" => 3,
      "destination_expected_revision" => 1
    }

    assert %{"results" => [transfer]} = post_batch(conn, [transfer_operation])

    assert post_batch(conn, [transfer_operation]) == %{"results" => [transfer]}

    assert transfer == %{
             "operation_id" => "move-deposit",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 150,
             "source_outstanding_deposit_cents" => 150,
             "destination_outstanding_deposit_cents" => 50,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert json_response(get(conn, "/api/v1/groups/source"), 200)["data"]
           |> Map.take([
             "revision",
             "cash_paid_cents",
             "credit_paid_cents",
             "outstanding_deposit_cents"
           ]) ==
             %{
               "revision" => 4,
               "cash_paid_cents" => 50,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 150
             }

    destination = json_response(get(conn, "/api/v1/groups/destination"), 200)["data"]

    assert destination
           |> Map.take([
             "revision",
             "cash_paid_cents",
             "credit_paid_cents",
             "outstanding_deposit_cents"
           ]) ==
             %{
               "revision" => 2,
               "cash_paid_cents" => 50,
               "credit_paid_cents" => 100,
               "outstanding_deposit_cents" => 50
             }

    assert Enum.map(
             destination["rooms"],
             &Map.take(&1, ["room_id", "cash_paid_cents", "credit_paid_cents"])
           ) == [
             %{"room_id" => "first", "cash_paid_cents" => 0, "credit_paid_cents" => 100},
             %{"room_id" => "second", "cash_paid_cents" => 50, "credit_paid_cents" => 0}
           ]

    assert json_response(get(conn, "/api/v1/payments/source-payment"), 200) == %{
             "data" => %{
               "payment_operation_id" => "source-payment",
               "original_group_id" => "source",
               "recorded_cents" => 100,
               "held_cents" => 100,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "destination", "amount_cents" => 50},
                 %{"group_id" => "source", "amount_cents" => 50}
               ]
             }
           }

    assert %{"results" => [cancelled]} =
             post_batch(conn, [cancellation("destination-cancel", "destination", "2026-10-06")])

    assert cancelled["refunded_cents"] == 50
    assert cancelled["credit_issued_cents"] == 0

    assert json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2026-10-06"), 200)["data"]
           |> Map.take(["available_cents", "lots"]) ==
             %{
               "available_cents" => 110,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-source-cancel",
                   "remaining_cents" => 110,
                   "expires_on" => "2027-10-05"
                 }
               ]
             }

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"]
           |> Map.take([
             "cash_held_cents",
             "cash_refunded_cents",
             "cash_converted_to_credit_cents"
           ]) ==
             %{
               "cash_held_cents" => 50,
               "cash_refunded_cents" => 50,
               "cash_converted_to_credit_cents" => 100
             }
  end

  test "reductions and chargebacks follow transferred cash across groups", %{conn: conn} do
    post_batch(conn, [
      open_operation("source", [%{"room_id" => "source-room", "nightly_rate_cents" => 500}]),
      cash_payment("source-payment", "source", 100),
      open_operation("destination", [
        %{"room_id" => "destination-room", "nightly_rate_cents" => 500}
      ])
    ])

    post_batch(conn, [transfer("move", "source", "destination", 50, 2, 1)])

    assert %{"results" => [reduced]} =
             post_batch(conn, [
               %{
                 "operation_id" => "reduce",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-06",
                 "payment_operation_id" => "source-payment",
                 "amount_cents" => 25,
                 "expected_revision" => 3
               }
             ])

    assert reduced == %{
             "operation_id" => "reduce",
             "status" => "applied",
             "payment_operation_id" => "source-payment",
             "group_id" => "source",
             "amount_cents" => 25,
             "outstanding_deposit_cents" => 50,
             "revision" => 4
           }

    assert json_response(get(conn, "/api/v1/groups/destination"), 200)["data"]
           |> Map.take(["revision", "cash_paid_cents", "outstanding_deposit_cents"]) ==
             %{"revision" => 3, "cash_paid_cents" => 25, "outstanding_deposit_cents" => 75}

    assert %{"results" => [chargeback]} =
             post_batch(conn, [
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-07",
                 "payment_operation_id" => "source-payment",
                 "expected_revision" => 4
               }
             ])

    assert chargeback["charged_back_cents"] == 75
    assert chargeback["revision"] == 5

    assert json_response(get(conn, "/api/v1/payments/source-payment"), 200)["data"]
           |> Map.take(["held_cents", "reduced_cents", "charged_back_cents", "held_by_group"]) ==
             %{
               "held_cents" => 0,
               "reduced_cents" => 25,
               "charged_back_cents" => 75,
               "held_by_group" => []
             }

    assert json_response(get(conn, "/api/v1/groups/source"), 200)["data"]
           |> Map.take(["revision", "cash_paid_cents", "outstanding_deposit_cents"]) ==
             %{"revision" => 5, "cash_paid_cents" => 0, "outstanding_deposit_cents" => 100}

    assert json_response(get(conn, "/api/v1/groups/destination"), 200)["data"]
           |> Map.take(["revision", "cash_paid_cents", "outstanding_deposit_cents"]) ==
             %{"revision" => 4, "cash_paid_cents" => 0, "outstanding_deposit_cents" => 100}
  end

  test "resolves transfer groups before revisions and remembers exact retries", %{conn: conn} do
    post_batch(conn, [
      open_operation("source", [%{"room_id" => "room", "nightly_rate_cents" => 500}]),
      open_operation("destination", [%{"room_id" => "room", "nightly_rate_cents" => 500}])
    ])

    missing_source = transfer("missing", "not-found", "destination", 1, 0, 1)

    assert post_batch(conn, [missing_source]) == %{
             "results" => [
               %{
                 "operation_id" => "missing",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "not-found"
               }
             ]
           }

    stale_destination = transfer("stale", "source", "destination", 1, 1, 0)

    assert post_batch(conn, [stale_destination]) == %{
             "results" => [
               %{
                 "operation_id" => "stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "destination",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           }

    assert post_batch(conn, [stale_destination]) == post_batch(conn, [stale_destination])
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open_operation(group_id, rooms) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => rooms
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancellation(operation_id, group_id, occurred_on, refund_method \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation
  end

  defp transfer(
         operation_id,
         source_group_id,
         destination_group_id,
         amount,
         source_revision,
         destination_revision
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-05",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount,
      "expected_revision" => source_revision,
      "destination_expected_revision" => destination_revision
    }
  end
end
