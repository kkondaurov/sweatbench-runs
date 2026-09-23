defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_group(operation_id, group_id, guest_id, rooms) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2027-03-10",
      "departure_on" => "2027-03-11",
      "rate_plan" => "flexible",
      "rooms" => rooms
    }
  end

  defp room(room_id, rate \\ 1_000),
    do: %{"room_id" => room_id, "nightly_rate_cents" => rate}

  defp cash_payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(operation_id, source_id, destination_id, amount, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "transfer_deposit",
        "source_group_id" => source_id,
        "destination_group_id" => destination_id,
        "amount_cents" => amount
      },
      extra
    )
  end

  defp data(conn, path) do
    conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  test "moves the newest mixed funding into destination rooms and preserves provenance", %{
    conn: conn
  } do
    donor = open_group("open-donor", "donor", "shared-guest", [room("donor-room", 10_000)])
    donor_payment = cash_payment("donor-payment", "donor", 1_000)

    donor_cancel = %{
      "operation_id" => "donor-credit",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-03",
      "group_id" => "donor",
      "refund_method" => "hotel_credit"
    }

    source = open_group("open-source", "source", "shared-guest", [room("source-room", 10_000)])

    destination =
      open_group("open-destination", "destination", "shared-guest", [
        room("destination-a"),
        room("destination-b"),
        room("destination-c")
      ])

    assert [
             %{"status" => "applied"},
             %{"status" => "applied"},
             %{"credit_issued_cents" => 1_100},
             %{"status" => "applied"},
             %{"status" => "applied"}
           ] =
             submit(conn, [donor, donor_payment, donor_cancel, source, destination])

    assert [
             %{"revision" => 2, "outstanding_deposit_cents" => 1_500},
             %{"revision" => 3, "outstanding_deposit_cents" => 1_000}
           ] =
             submit(conn, [
               %{
                 "operation_id" => "source-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-04",
                 "group_id" => "source",
                 "amount_cents" => 500
               },
               cash_payment("source-payment", "source", 500)
             ])

    ledger_before_transfer = data(conn, "/api/v1/ledger?on=2027-01-04")

    move =
      transfer("move-mixed", "source", "destination", 550, %{
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      })

    [move_result] = submit(conn, [move])

    assert move_result == %{
             "operation_id" => "move-mixed",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 550,
             "source_outstanding_deposit_cents" => 1_550,
             "destination_outstanding_deposit_cents" => 50,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert data(conn, "/api/v1/ledger?on=2027-01-04") == ledger_before_transfer
    assert ledger_before_transfer["credit_liability_cents"] == 1_100
    assert [^move_result] = submit(conn, [move])

    source_group = data(conn, "/api/v1/groups/source")
    assert source_group["revision"] == 4
    assert source_group["cash_paid_cents"] == 0
    assert source_group["credit_paid_cents"] == 450
    assert hd(source_group["rooms"])["credit_paid_cents"] == 450

    destination_group = data(conn, "/api/v1/groups/destination")
    assert destination_group["revision"] == 2

    assert Enum.map(destination_group["rooms"], & &1["cash_paid_cents"]) == [200, 200, 100]
    assert Enum.map(destination_group["rooms"], & &1["credit_paid_cents"]) == [0, 0, 50]

    payment_statement = data(conn, "/api/v1/payments/source-payment")

    assert payment_statement["held_cents"] == 500

    assert payment_statement["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 500}
           ]

    cancel_destination = %{
      "operation_id" => "cancel-destination",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-05",
      "group_id" => "destination",
      "expected_revision" => 2
    }

    assert [%{"status" => "applied", "refunded_cents" => 500, "revision" => 3}] =
             submit(conn, [cancel_destination])

    assert data(conn, "/api/v1/guests/shared-guest/credit?on=2027-01-05")["available_cents"] ==
             650

    assert data(conn, "/api/v1/ledger?on=2027-01-05")["credit_liability_cents"] == 1_100

    assert data(conn, "/api/v1/payments/source-payment")["held_by_group"] == []
    assert data(conn, "/api/v1/payments/source-payment")["refunded_cents"] == 500
  end

  test "reductions and chargebacks follow a transferred payment across group revisions", %{
    conn: conn
  } do
    source = open_group("open-cash-source", "cash-source", "cash-guest", [room("source", 10_000)])

    destination =
      open_group("open-cash-destination", "cash-destination", "cash-guest", [
        room("destination", 10_000)
      ])

    assert [%{"status" => "applied"}, %{"status" => "applied"}] =
             submit(conn, [source, destination])

    assert [
             %{"status" => "applied", "revision" => 2},
             %{"status" => "applied", "source_revision" => 3, "destination_revision" => 2}
           ] =
             submit(conn, [
               cash_payment("shared-payment", "cash-source", 1_000),
               transfer("move-cash", "cash-source", "cash-destination", 700)
             ])

    reduction = %{
      "operation_id" => "reduce-shared-payment",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "shared-payment",
      "amount_cents" => 500
    }

    assert [%{"status" => "applied", "revision" => 4, "outstanding_deposit_cents" => 1_700}] =
             submit(conn, [reduction])

    assert data(conn, "/api/v1/groups/cash-source")["revision"] == 4
    assert data(conn, "/api/v1/groups/cash-destination")["revision"] == 3
    assert data(conn, "/api/v1/groups/cash-source")["cash_paid_cents"] == 300
    assert data(conn, "/api/v1/groups/cash-destination")["cash_paid_cents"] == 200

    assert data(conn, "/api/v1/payments/shared-payment")["held_by_group"] == [
             %{"group_id" => "cash-destination", "amount_cents" => 200},
             %{"group_id" => "cash-source", "amount_cents" => 300}
           ]

    chargeback = %{
      "operation_id" => "chargeback-shared-payment",
      "type" => "charge_back_payment",
      "payment_operation_id" => "shared-payment"
    }

    assert [%{"status" => "applied", "charged_back_cents" => 500, "revision" => 5}] =
             submit(conn, [chargeback])

    assert data(conn, "/api/v1/groups/cash-source")["revision"] == 5
    assert data(conn, "/api/v1/groups/cash-destination")["revision"] == 4
    assert data(conn, "/api/v1/groups/cash-source")["cash_paid_cents"] == 0
    assert data(conn, "/api/v1/groups/cash-destination")["cash_paid_cents"] == 0

    assert data(conn, "/api/v1/payments/shared-payment") == %{
             "payment_operation_id" => "shared-payment",
             "original_group_id" => "cash-source",
             "recorded_cents" => 1_000,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 500,
             "charged_back_cents" => 500,
             "held_by_group" => []
           }

    ledger = data(conn, "/api/v1/ledger")
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_reduced_cents"] == 500
    assert ledger["cash_charged_back_cents"] == 500
  end

  test "resolves groups and checks both revisions before transfer validation", %{conn: conn} do
    source =
      open_group("open-validation-source", "validation-source", "validation-guest", [room("s")])

    destination =
      open_group("open-validation-destination", "validation-destination", "validation-guest", [
        room("d")
      ])

    other_guest =
      open_group("open-other-guest", "other-guest", "different-guest", [room("other")])

    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             submit(conn, [source, destination, other_guest])

    assert [%{"status" => "applied"}] =
             submit(conn, [cash_payment("validation-payment", "validation-source", 100)])

    assert [%{"status" => "applied"}] =
             submit(conn, [
               cash_payment("validation-destination-payment", "validation-destination", 150)
             ])

    assert [%{"code" => "group_not_found", "group_id" => "missing-source"}] =
             submit(conn, [
               transfer("missing-source-transfer", "missing-source", "missing-dest", 1)
             ])

    assert [%{"code" => "group_not_found", "group_id" => "missing-dest"}] =
             submit(conn, [
               transfer("missing-destination-transfer", "validation-source", "missing-dest", 1, %{
                 "expected_revision" => 1
               })
             ])

    assert [%{"code" => "stale_revision", "group_id" => "validation-source"}] =
             submit(conn, [
               transfer(
                 "stale-source-transfer",
                 "validation-source",
                 "validation-destination",
                 0,
                 %{
                   "expected_revision" => 1,
                   "destination_expected_revision" => 0
                 }
               )
             ])

    assert [%{"code" => "stale_revision", "group_id" => "validation-destination"}] =
             submit(conn, [
               transfer(
                 "stale-destination-transfer",
                 "validation-source",
                 "validation-destination",
                 0,
                 %{
                   "expected_revision" => 2,
                   "destination_expected_revision" => 0
                 }
               )
             ])

    assert [%{"code" => "invalid_transfer"}] =
             submit(conn, [
               transfer("same-group-transfer", "validation-source", "validation-source", 1, %{
                 "expected_revision" => 2,
                 "destination_expected_revision" => 2
               })
             ])

    assert [%{"code" => "invalid_transfer"}] =
             submit(conn, [
               transfer("different-guest-transfer", "validation-source", "other-guest", 1)
             ])

    assert [%{"code" => "invalid_amount"}] =
             submit(conn, [
               transfer("bad-amount-transfer", "validation-source", "validation-destination", 0)
             ])

    assert [%{"code" => "transfer_exceeds_held_funding"}] =
             submit(conn, [
               transfer(
                 "excess-held-transfer",
                 "validation-source",
                 "validation-destination",
                 101
               )
             ])

    assert [%{"code" => "transfer_exceeds_outstanding"}] =
             submit(conn, [
               transfer("excess-due-transfer", "validation-source", "validation-destination", 100)
             ])

    assert [%{"status" => "applied", "revision" => 3}] =
             submit(conn, [
               %{
                 "operation_id" => "cancel-validation-destination",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-03",
                 "group_id" => "validation-destination",
                 "expected_revision" => 2
               }
             ])

    assert [%{"code" => "group_not_active", "group_id" => "validation-destination"}] =
             submit(conn, [
               transfer(
                 "inactive-destination-transfer",
                 "validation-source",
                 "validation-destination",
                 1,
                 %{
                   "expected_revision" => 2,
                   "destination_expected_revision" => 3
                 }
               )
             ])
  end
end
