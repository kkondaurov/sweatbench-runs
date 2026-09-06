defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Repo}

  defp operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-group",
        "type" => "open_group",
        "occurred_on" => "2027-02-01",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-15",
        "departure_on" => "2027-04-16",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 7_500},
          %{"room_id" => "room-b", "nightly_rate_cents" => 7_500}
        ]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  test "allocates funding by room and cancels only the selected rooms", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} = post_batch(conn, [operation()])

    assert %{"results" => [%{"revision" => 2, "outstanding_deposit_cents" => 0}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "pay-17",
                 "type" => "record_cash_payment",
                 "amount_cents" => 3_000
               })
             ])

    assert %{"data" => %{"rooms" => rooms}} =
             get(conn, "/api/v1/groups/group-81") |> json_response(200)

    assert [
             %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 1_500},
             %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 1_500}
           ] = rooms

    assert %{
             "results" => [
               %{
                 "cancelled_room_ids" => ["room-a"],
                 "refunded_cents" => 1_500,
                 "revision" => 3
               }
             ]
           } =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "cancel-room-a",
                 "type" => "cancel_rooms",
                 "room_ids" => ["room-a"],
                 "occurred_on" => "2027-03-01"
               })
             ])

    assert %{
             "data" => %{
               "lodging_total_cents" => 7_500,
               "deposit_due_cents" => 1_500,
               "cash_paid_cents" => 1_500,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
                 %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 1_500}
               ]
             }
           } = get(conn, "/api/v1/groups/group-81") |> json_response(200)
  end

  test "reduces and charges back a payment while preserving its original result", %{conn: conn} do
    post_batch(conn, [operation()])

    assert %{"results" => [%{"amount_cents" => 3_000} = original_payment]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "pay-17",
                 "type" => "record_cash_payment",
                 "amount_cents" => 3_000
               })
             ])

    assert %{"results" => [%{"amount_cents" => 500, "revision" => 3}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "reduce-17",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay-17",
                 "amount_cents" => 500
               })
             ])

    assert %{"results" => [%{"charged_back_cents" => 2_500, "revision" => 4}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "chargeback-17",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay-17"
               })
             ])

    assert %{"results" => [^original_payment]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "pay-17",
                 "type" => "record_cash_payment",
                 "amount_cents" => 3_000
               })
             ])

    assert %{
             "data" => %{
               "recorded_cents" => 3_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 500,
               "charged_back_cents" => 2_500
             }
           } = get(conn, "/api/v1/payments/pay-17") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_reduced_cents" => 500,
               "cash_charged_back_cents" => 2_500
             }
           } = get(conn, "/api/v1/ledger") |> json_response(200)
  end

  test "a chargeback revokes unspent hotel credit and its bonus", %{conn: conn} do
    post_batch(conn, [operation()])

    post_batch(conn, [
      operation(%{
        "operation_id" => "pay-source",
        "type" => "record_cash_payment",
        "amount_cents" => 2_000
      })
    ])

    assert %{"results" => [%{"credit_issued_cents" => 2_200}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "cancel-source",
                 "type" => "cancel_group",
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2027-03-01"
               })
             ])

    assert %{"data" => %{"available_cents" => 2_200}} =
             get(conn, "/api/v1/guests/guest-22/credit?on=2027-03-01") |> json_response(200)

    assert %{"results" => [%{"charged_back_cents" => 2_000}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "chargeback-source",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay-source"
               })
             ])

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(conn, "/api/v1/guests/guest-22/credit?on=2027-03-01") |> json_response(200)
  end

  test "a chargeback records a shortfall until applied credit is consumed", %{conn: conn} do
    post_batch(conn, [operation()])

    post_batch(conn, [
      operation(%{
        "operation_id" => "pay-source",
        "type" => "record_cash_payment",
        "amount_cents" => 3_000
      })
    ])

    post_batch(conn, [
      operation(%{
        "operation_id" => "cancel-source",
        "type" => "cancel_group",
        "refund_method" => "hotel_credit",
        "occurred_on" => "2027-03-01"
      })
    ])

    post_batch(conn, [
      operation(%{
        "operation_id" => "open-target",
        "type" => "open_group",
        "group_id" => "target",
        "rooms" => [%{"room_id" => "target-room", "nightly_rate_cents" => 16_500}]
      })
    ])

    post_batch(conn, [
      operation(%{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "group_id" => "target",
        "amount_cents" => 3_300,
        "occurred_on" => "2027-03-02"
      })
    ])

    post_batch(conn, [
      operation(%{
        "operation_id" => "chargeback-source",
        "type" => "charge_back_payment",
        "payment_operation_id" => "pay-source"
      })
    ])

    assert %{
             "data" => %{
               "credit_liability_cents" => 3_300,
               "credit_shortfall_cents" => 3_300
             }
           } = get(conn, "/api/v1/ledger") |> json_response(200)

    post_batch(conn, [
      operation(%{
        "operation_id" => "cancel-target",
        "type" => "cancel_group",
        "group_id" => "target",
        "occurred_on" => "2027-04-01"
      })
    ])

    assert %{
             "data" => %{
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           } = get(conn, "/api/v1/ledger") |> json_response(200)
  end

  test "chargeback distinguishes missing and non-payment targets", %{conn: conn} do
    post_batch(conn, [operation()])

    assert %{"results" => [%{"code" => "operation_not_found"}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "chargeback-missing",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "missing"
               })
             ])

    assert %{"results" => [%{"code" => "payment_not_chargeable"}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "chargeback-open",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "open-group"
               })
             ])
  end

  test "reads legacy funding as a senior block before durable funding", %{conn: conn} do
    Repo.insert!(%Group{
      group_id: "legacy",
      guest_id: "guest-legacy",
      property_id: "ams-canal",
      booked_on: ~D[2027-02-01],
      arrival_on: ~D[2027-04-15],
      departure_on: ~D[2027-04-16],
      rate_plan: "flexible",
      policy_version: "flex-30",
      status: "active",
      rooms_json:
        Jason.encode!([
          %{"room_id" => "room-a", "nightly_rate_cents" => 1_500},
          %{"room_id" => "room-b", "nightly_rate_cents" => 1_500}
        ]),
      lodging_total_cents: 3_000,
      deposit_due_cents: 600,
      deposit_paid_cents: 600,
      cash_paid_cents: 300,
      credit_paid_cents: 300,
      refunded_cents: 0,
      retained_cents: 0,
      cash_converted_to_credit_cents: 0,
      cash_reduced_cents: 0,
      cash_charged_back_cents: 0,
      revision: 1
    })

    lot =
      Repo.insert!(%CreditLot{
        guest_id: "guest-legacy",
        source_operation_id: "legacy-credit-source",
        remaining_cents: 0,
        issued_on: ~D[2027-01-01],
        expires_on: ~D[2028-01-01],
        unrecovered_clawback_cents: 0
      })

    Repo.insert!(%CreditAllocation{
      group_id: "legacy",
      credit_lot_id: lot.id,
      amount_cents: 300
    })

    for {operation_id, type, amount} <- [
          {"legacy-pay", "record_cash_payment", 100},
          {"legacy-credit", "apply_hotel_credit", 100}
        ] do
      Repo.insert!(%Operation{
        operation_id: operation_id,
        type: type,
        payload_json: Jason.encode!(%{"operation_id" => operation_id, "type" => type}),
        result_json:
          Jason.encode!(%{
            "operation_id" => operation_id,
            "status" => "applied",
            "group_id" => "legacy",
            "amount_cents" => amount
          })
      })
    end

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 200, "credit_paid_cents" => 100},
                 %{"room_id" => "room-b", "cash_paid_cents" => 100, "credit_paid_cents" => 200}
               ]
             }
           } = get(conn, "/api/v1/groups/legacy") |> json_response(200)
  end
end
