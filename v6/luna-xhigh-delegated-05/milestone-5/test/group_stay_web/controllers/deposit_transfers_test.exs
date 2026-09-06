defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(group_id, guest_id, operation_id, room_count \\ 2) do
    %{
      operation_id: operation_id,
      type: "open_group",
      occurred_on: "2026-10-03",
      group_id: group_id,
      guest_id: guest_id,
      property_id: "ams-canal",
      arrival_on: "2027-02-01",
      departure_on: "2027-02-02",
      rate_plan: "flexible",
      rooms:
        Enum.map(1..room_count, fn index ->
          %{room_id: "room-#{index}", nightly_rate_cents: 5_000}
        end)
    }
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

  test "moves mixed cash and credit by reverse allocation order and keeps provenance", %{
    conn: conn
  } do
    submit(conn, [
      open_operation("credit-source", "transfer-guest", "open-credit-source", 1),
      payment("credit-source", "pay-credit-source", 500),
      %{
        operation_id: "cancel-credit-source",
        type: "cancel_group",
        occurred_on: "2027-01-01",
        group_id: "credit-source",
        refund_method: "hotel_credit"
      },
      open_operation("source", "transfer-guest", "open-source"),
      payment("source", "pay-source", 1_000),
      %{
        operation_id: "apply-source-credit",
        type: "apply_hotel_credit",
        occurred_on: "2027-01-01",
        group_id: "source",
        amount_cents: 500
      },
      open_operation("destination", "transfer-guest", "open-destination")
    ])
    |> json_response(200)

    result =
      submit(conn, [
        %{
          operation_id: "transfer-mixed",
          type: "transfer_deposit",
          source_group_id: "source",
          destination_group_id: "destination",
          amount_cents: 1_200,
          expected_revision: 3,
          destination_expected_revision: 1
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result == %{
             "operation_id" => "transfer-mixed",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 1_200,
             "source_outstanding_deposit_cents" => 1_700,
             "destination_outstanding_deposit_cents" => 800,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    source = get(conn, "/api/v1/groups/source") |> json_response(200)

    assert Enum.map(source["data"]["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) ==
             [
               {300, 0},
               {0, 0}
             ]

    destination = get(conn, "/api/v1/groups/destination") |> json_response(200)

    assert Enum.map(
             destination["data"]["rooms"],
             &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
           ) == [
             {500, 500},
             {200, 0}
           ]

    assert get(conn, "/api/v1/payments/pay-source") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "pay-source",
               "original_group_id" => "source",
               "recorded_cents" => 1_000,
               "held_cents" => 1_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "destination", "amount_cents" => 700},
                 %{"group_id" => "source", "amount_cents" => 300}
               ]
             }
           }

    retry =
      submit(conn, [
        %{
          operation_id: "transfer-mixed",
          type: "transfer_deposit",
          source_group_id: "source",
          destination_group_id: "destination",
          amount_cents: 1_200,
          expected_revision: 3,
          destination_expected_revision: 1
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert retry == result

    assert get(conn, "/api/v1/groups/source")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 4

    assert get(conn, "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2
  end

  test "checks source then destination revisions and reports transfer validation errors", %{
    conn: conn
  } do
    submit(conn, [
      open_operation("source", "same-guest", "open-source", 1),
      open_operation("destination", "same-guest", "open-destination", 1),
      payment("source", "pay-source", 1_000)
    ])
    |> json_response(200)

    source_stale =
      submit(conn, [
        %{
          operation_id: "source-stale",
          type: "transfer_deposit",
          source_group_id: "source",
          destination_group_id: "destination",
          amount_cents: 1,
          expected_revision: 1,
          destination_expected_revision: 99
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert source_stale == %{
             "operation_id" => "source-stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "source",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    destination_stale =
      submit(conn, [
        %{
          operation_id: "destination-stale",
          type: "transfer_deposit",
          source_group_id: "source",
          destination_group_id: "destination",
          amount_cents: 1,
          expected_revision: 2,
          destination_expected_revision: 0
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert destination_stale == %{
             "operation_id" => "destination-stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "destination",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    assert submit(conn, [
             %{
               operation_id: "bad-amount",
               type: "transfer_deposit",
               source_group_id: "source",
               destination_group_id: "destination",
               amount_cents: 0,
               expected_revision: 2,
               destination_expected_revision: 1
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "code"]) == "invalid_amount"

    assert submit(conn, [
             %{
               operation_id: "too-much",
               type: "transfer_deposit",
               source_group_id: "source",
               destination_group_id: "destination",
               amount_cents: 1_001,
               expected_revision: 2,
               destination_expected_revision: 1
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "code"]) == "transfer_exceeds_held_funding"
  end

  test "reductions and chargebacks follow transferred cash across groups", %{conn: conn} do
    submit(conn, [
      open_operation("source", "cross-group-guest", "open-source", 1),
      open_operation("destination", "cross-group-guest", "open-destination", 1),
      payment("source", "pay-source", 1_000),
      %{
        operation_id: "transfer-cash",
        type: "transfer_deposit",
        source_group_id: "source",
        destination_group_id: "destination",
        amount_cents: 1_000,
        expected_revision: 2,
        destination_expected_revision: 1
      }
    ])
    |> json_response(200)

    assert submit(conn, [
             %{
               operation_id: "cancel-empty-source",
               type: "cancel_group",
               occurred_on: "2027-01-01",
               group_id: "source",
               expected_revision: 3
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "revision"]) == 4

    reduced =
      submit(conn, [
        %{
          operation_id: "reduce-transferred",
          type: "reduce_cash_payment",
          payment_operation_id: "pay-source",
          amount_cents: 400,
          expected_revision: 4
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert reduced["revision"] == 5

    assert get(conn, "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 3

    assert get(conn, "/api/v1/payments/pay-source")
           |> json_response(200)
           |> get_in(["data", "held_by_group"]) == [
             %{"group_id" => "destination", "amount_cents" => 600}
           ]

    charged_back =
      submit(conn, [
        %{
          operation_id: "charge-transferred",
          type: "charge_back_payment",
          payment_operation_id: "pay-source",
          expected_revision: 5
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert charged_back["revision"] == 6

    assert get(conn, "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 4

    assert get(conn, "/api/v1/payments/pay-source") |> json_response(200) |> get_in(["data"]) ==
             %{
               "payment_operation_id" => "pay-source",
               "original_group_id" => "source",
               "recorded_cents" => 1_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 400,
               "charged_back_cents" => 600,
               "held_by_group" => []
             }
  end

  test "settles transferred credit at the destination without a second credit bonus", %{
    conn: conn
  } do
    submit(conn, [
      open_operation("credit-source", "settlement-guest", "open-credit-source", 1),
      payment("credit-source", "pay-credit", 500),
      %{
        operation_id: "cancel-credit",
        type: "cancel_group",
        occurred_on: "2027-01-01",
        group_id: "credit-source",
        refund_method: "hotel_credit"
      },
      open_operation("source", "settlement-guest", "open-source", 1),
      payment("source", "pay-source", 500),
      %{
        operation_id: "apply-credit",
        type: "apply_hotel_credit",
        occurred_on: "2027-01-01",
        group_id: "source",
        amount_cents: 500
      },
      open_operation("destination", "settlement-guest", "open-destination", 1),
      %{
        operation_id: "transfer-credit",
        type: "transfer_deposit",
        source_group_id: "source",
        destination_group_id: "destination",
        amount_cents: 1_000,
        expected_revision: 3,
        destination_expected_revision: 1
      }
    ])
    |> json_response(200)

    result =
      submit(conn, [
        %{
          operation_id: "cancel-destination",
          type: "cancel_group",
          occurred_on: "2027-01-01",
          group_id: "destination",
          refund_method: "hotel_credit",
          expected_revision: 2
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result["credit_issued_cents"] == 550

    assert get(conn, "/api/v1/guests/settlement-guest/credit?on=2027-01-01")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 1_100

    assert get(conn, "/api/v1/payments/pay-source") |> json_response(200) |> get_in(["data"]) ==
             %{
               "payment_operation_id" => "pay-source",
               "original_group_id" => "source",
               "recorded_cents" => 500,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 500,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => []
             }
  end
end
