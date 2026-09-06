defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  test "moves mixed held funding in reverse allocation order and keeps payment provenance", %{
    conn: conn
  } do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_batch(conn, [
               open("credit-origin", "2027-01-01", "2027-04-01", "credit-origin-room"),
               cash_payment("credit-origin-pay", "credit-origin", 100, 1),
               cancel("credit-origin-cancel", "credit-origin", 2, "2027-01-02", "hotel_credit")
             ])

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_batch(conn, [
               open(
                 "transfer-source",
                 "2027-01-01",
                 "2027-04-01",
                 "source-room-a",
                 "source-room-b"
               ),
               cash_payment("transfer-pay", "transfer-source", 150, 1),
               credit_payment("transfer-credit", "transfer-source", 50, 2, "2027-01-03")
             ])

    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [
               open(
                 "transfer-destination",
                 "2027-01-01",
                 "2027-04-01",
                 "destination-room-a",
                 "destination-room-b"
               )
             ])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "amount_cents" => 150,
                 "source_outstanding_deposit_cents" => 150,
                 "destination_outstanding_deposit_cents" => 50,
                 "source_revision" => 4,
                 "destination_revision" => 2
               }
             ]
           } =
             post_batch(conn, [
               transfer(
                 "transfer-1",
                 "transfer-source",
                 "transfer-destination",
                 150,
                 3,
                 1
               )
             ])

    assert %{
             "data" => %{
               "revision" => 4,
               "deposit_paid_cents" => 50,
               "cash_paid_cents" => 50,
               "credit_paid_cents" => 0,
               "rooms" => [
                 %{"room_id" => "source-room-a", "cash_paid_cents" => 50},
                 %{"room_id" => "source-room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
               ]
             }
           } = json_response(get(conn, "/api/v1/groups/transfer-source"), 200)

    assert %{
             "data" => %{
               "revision" => 2,
               "deposit_paid_cents" => 150,
               "cash_paid_cents" => 100,
               "credit_paid_cents" => 50,
               "rooms" => [
                 %{
                   "room_id" => "destination-room-a",
                   "cash_paid_cents" => 50,
                   "credit_paid_cents" => 50
                 },
                 %{
                   "room_id" => "destination-room-b",
                   "cash_paid_cents" => 50,
                   "credit_paid_cents" => 0
                 }
               ]
             }
           } = json_response(get(conn, "/api/v1/groups/transfer-destination"), 200)

    assert %{"data" => statement} = json_response(get(conn, "/api/v1/payments/transfer-pay"), 200)

    assert statement["held_cents"] == 150

    assert statement["held_by_group"] == [
             %{"group_id" => "transfer-destination", "amount_cents" => 100},
             %{"group_id" => "transfer-source", "amount_cents" => 50}
           ]

    assert %{"data" => ledger} = json_response(get(conn, "/api/v1/ledger"), 200)
    assert ledger["cash_held_cents"] == 150
    assert ledger["credit_liability_cents"] == 110
  end

  test "checks both revisions before transfer validation and replays transfers durably", %{
    conn: conn
  } do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 1}]} =
             post_batch(conn, [
               open("revision-source", "2027-01-01", "2027-04-01", "source-room"),
               open("revision-destination", "2027-01-01", "2027-04-01", "destination-room")
             ])

    assert %{"results" => [%{"revision" => 2}]} =
             post_batch(conn, [cash_payment("revision-pay", "revision-source", 50, 1)])

    assert %{
             "results" => [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "revision-destination",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           } =
             post_batch(conn, [
               transfer("stale-destination", "revision-source", "revision-destination", -1, 2, 0)
             ])

    applied =
      transfer("valid-transfer", "revision-source", "revision-destination", 50, 2, 1)

    assert %{"results" => [%{"source_revision" => 3, "destination_revision" => 2}]} =
             post_batch(conn, [applied])

    assert %{"results" => [replayed]} = post_batch(conn, [applied])
    assert replayed["source_revision"] == 3
    assert replayed["destination_revision"] == 2

    assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 0}} =
             json_response(get(conn, "/api/v1/groups/revision-source"), 200)

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 50}} =
             json_response(get(conn, "/api/v1/groups/revision-destination"), 200)
  end

  test "reductions and chargebacks follow transferred cash allocations", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open(
                 "correction-source",
                 "2027-01-01",
                 "2027-04-01",
                 "source-room",
                 "source-room-b"
               ),
               open("correction-destination", "2027-01-01", "2027-04-01", "destination-room"),
               cash_payment("correction-pay", "correction-source", 150, 1)
             ])

    assert %{"results" => [%{"source_revision" => 3, "destination_revision" => 2}]} =
             post_batch(conn, [
               transfer(
                 "correction-transfer",
                 "correction-source",
                 "correction-destination",
                 100,
                 2,
                 1
               )
             ])

    assert %{"results" => [%{"revision" => 4, "outstanding_deposit_cents" => 150}]} =
             post_batch(conn, [reduce("correction-reduce", "correction-pay", 80, 3)])

    assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 20}} =
             json_response(get(conn, "/api/v1/groups/correction-destination"), 200)

    assert %{"results" => [%{"revision" => 5, "charged_back_cents" => 70}]} =
             post_batch(conn, [charge_back("correction-chargeback", "correction-pay", 4)])

    assert %{"data" => %{"revision" => 4, "deposit_paid_cents" => 0}} =
             json_response(get(conn, "/api/v1/groups/correction-destination"), 200)

    assert %{"data" => statement} =
             json_response(get(conn, "/api/v1/payments/correction-pay"), 200)

    assert statement["held_cents"] == 0
    assert statement["reduced_cents"] == 80
    assert statement["charged_back_cents"] == 70
    assert statement["held_by_group"] == []

    assert %{"data" => ledger} = json_response(get(conn, "/api/v1/ledger"), 200)
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_reduced_cents"] == 80
    assert ledger["cash_charged_back_cents"] == 70
  end

  test "rejects a transfer that exceeds the destination outstanding deposit", %{conn: conn} do
    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"revision" => 2}
             ]
           } =
             post_batch(conn, [
               open("outstanding-source", "2027-01-01", "2027-04-01", "source-room"),
               open("outstanding-destination", "2027-01-01", "2027-04-01", "destination-room"),
               cash_payment("outstanding-source-pay", "outstanding-source", 50, 1),
               cash_payment("outstanding-destination-pay", "outstanding-destination", 100, 1)
             ])

    assert %{"results" => [%{"code" => "transfer_exceeds_outstanding"}]} =
             post_batch(conn, [
               transfer(
                 "outstanding-transfer",
                 "outstanding-source",
                 "outstanding-destination",
                 1,
                 2,
                 2
               )
             ])

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 50}} =
             json_response(get(conn, "/api/v1/groups/outstanding-source"), 200)

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 100}} =
             json_response(get(conn, "/api/v1/groups/outstanding-destination"), 200)
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open(group_id, booked_on, arrival_on, room_id, second_room_id \\ nil) do
    rooms = [%{"room_id" => room_id, "nightly_rate_cents" => 500}]

    rooms =
      if second_room_id,
        do: rooms ++ [%{"room_id" => second_room_id, "nightly_rate_cents" => 500}],
        else: rooms

    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => booked_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => Date.to_iso8601(Date.add(Date.from_iso8601!(arrival_on), 1)),
      "rate_plan" => "flexible",
      "rooms" => rooms
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp credit_payment(operation_id, group_id, amount_cents, expected_revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp cancel(operation_id, group_id, expected_revision, occurred_on, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision,
      "refund_method" => refund_method
    }
  end

  defp transfer(
         operation_id,
         source_group_id,
         destination_group_id,
         amount_cents,
         source_revision,
         destination_revision
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2027-01-04",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => source_revision,
      "destination_expected_revision" => destination_revision
    }
  end

  defp reduce(operation_id, payment_operation_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-01-05",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp charge_back(operation_id, payment_operation_id, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-06",
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision
    }
  end
end
