defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  test "transfers cash and credit in allocation order and settles them at the destination", %{
    conn: conn
  } do
    response =
      submit(conn, [
        open_group("open-credit", "credit-source", [room("credit-room", 10_000)]),
        cash_payment("pay-credit", "credit-source", 1_000, 1),
        cancel_group("cancel-credit", "credit-source", 2, "hotel_credit"),
        open_group("open-source", "source", [room("source-a", 10_000), room("source-b", 10_000)]),
        cash_payment("pay-source", "source", 3_000, 1),
        apply_credit("apply-source", "source", 1_000, 2),
        open_group("open-destination", "destination", [
          room("destination-a", 10_000),
          room("destination-b", 10_000)
        ]),
        transfer("transfer-1", "source", "destination", 2_500, 3, 1)
      ])

    assert Enum.at(response["results"], 7) == %{
             "operation_id" => "transfer-1",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 2_500,
             "source_outstanding_deposit_cents" => 2_500,
             "destination_outstanding_deposit_cents" => 1_500,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert group(conn, "source")
           |> Map.take([
             "revision",
             "cash_paid_cents",
             "credit_paid_cents",
             "outstanding_deposit_cents",
             "rooms"
           ]) ==
             %{
               "revision" => 4,
               "cash_paid_cents" => 1_500,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 2_500,
               "rooms" => [
                 %{
                   "room_id" => "source-a",
                   "nightly_rate_cents" => 10_000,
                   "status" => "active",
                   "lodging_total_cents" => 10_000,
                   "deposit_due_cents" => 2_000,
                   "cash_paid_cents" => 1_500,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "source-b",
                   "nightly_rate_cents" => 10_000,
                   "status" => "active",
                   "lodging_total_cents" => 10_000,
                   "deposit_due_cents" => 2_000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ]
             }

    assert group(conn, "destination")
           |> Map.take([
             "revision",
             "cash_paid_cents",
             "credit_paid_cents",
             "outstanding_deposit_cents",
             "rooms"
           ]) ==
             %{
               "revision" => 2,
               "cash_paid_cents" => 1_500,
               "credit_paid_cents" => 1_000,
               "outstanding_deposit_cents" => 1_500,
               "rooms" => [
                 %{
                   "room_id" => "destination-a",
                   "nightly_rate_cents" => 10_000,
                   "status" => "active",
                   "lodging_total_cents" => 10_000,
                   "deposit_due_cents" => 2_000,
                   "cash_paid_cents" => 1_000,
                   "credit_paid_cents" => 1_000
                 },
                 %{
                   "room_id" => "destination-b",
                   "nightly_rate_cents" => 10_000,
                   "status" => "active",
                   "lodging_total_cents" => 10_000,
                   "deposit_due_cents" => 2_000,
                   "cash_paid_cents" => 500,
                   "credit_paid_cents" => 0
                 }
               ]
             }

    assert payment(conn, "pay-source") == %{
             "payment_operation_id" => "pay-source",
             "original_group_id" => "source",
             "recorded_cents" => 3_000,
             "held_cents" => 3_000,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0,
             "held_by_group" => [
               %{"group_id" => "destination", "amount_cents" => 1_500},
               %{"group_id" => "source", "amount_cents" => 1_500}
             ]
           }

    assert ledger(conn) == %{
             "cash_held_cents" => 3_000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 1_000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 1_100,
             "credit_shortfall_cents" => 0
           }

    assert submit(conn, [cancel_group("cancel-destination", "destination", 2, "hotel_credit")]) ==
             %{
               "results" => [
                 %{
                   "operation_id" => "cancel-destination",
                   "status" => "applied",
                   "group_id" => "destination",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 1_650,
                   "revision" => 3
                 }
               ]
             }

    assert payment(conn, "pay-source") == %{
             "payment_operation_id" => "pay-source",
             "original_group_id" => "source",
             "recorded_cents" => 3_000,
             "held_cents" => 1_500,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 1_500,
             "reduced_cents" => 0,
             "charged_back_cents" => 0,
             "held_by_group" => [%{"group_id" => "source", "amount_cents" => 1_500}]
           }

    assert ledger(conn)["credit_liability_cents"] == 2_750
  end

  test "validates both groups and revision guards before transfer rules and replays transfers", %{
    conn: conn
  } do
    response =
      submit(conn, [
        transfer("missing-source", "missing", "destination", 1),
        open_group("open-source", "source", [room("source-room", 10_000)]),
        transfer("missing-destination", "source", "missing", 1),
        open_group("open-destination", "destination", [room("destination-room", 10_000)]),
        transfer("stale-source", "source", "destination", 1, 0, 1),
        transfer("stale-destination", "source", "destination", 1, 1, 0),
        transfer("invalid-amount", "source", "destination", 0, 1, 1),
        transfer("exceeds-held", "source", "destination", 1, 1, 1),
        cash_payment("pay-source", "source", 1_000, 1),
        transfer("transfer-1", "source", "destination", 1_000, 2, 1),
        cancel_group("cancel-source", "source", 3),
        transfer("inactive-source", "source", "destination", 1, 4, 2),
        open_group("open-other", "other", [room("other-room", 10_000)], "other-guest"),
        transfer("different-guest", "source", "other", 1, 4, 1)
      ])

    assert Enum.at(response["results"], 0) == %{
             "operation_id" => "missing-source",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "missing"
           }

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "missing-destination",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "missing"
           }

    assert Enum.at(response["results"], 4) == %{
             "operation_id" => "stale-source",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "source",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    assert Enum.at(response["results"], 5) == %{
             "operation_id" => "stale-destination",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "destination",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    assert Enum.at(response["results"], 6) == %{
             "operation_id" => "invalid-amount",
             "status" => "rejected",
             "code" => "invalid_amount"
           }

    assert Enum.at(response["results"], 7) == %{
             "operation_id" => "exceeds-held",
             "status" => "rejected",
             "code" => "transfer_exceeds_held_funding"
           }

    transfer_result = Enum.at(response["results"], 9)

    assert transfer_result == %{
             "operation_id" => "transfer-1",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 1_000,
             "source_outstanding_deposit_cents" => 2_000,
             "destination_outstanding_deposit_cents" => 1_000,
             "source_revision" => 3,
             "destination_revision" => 2
           }

    assert Enum.at(response["results"], 11) == %{
             "operation_id" => "inactive-source",
             "status" => "rejected",
             "code" => "group_not_active",
             "group_id" => "source"
           }

    assert Enum.at(response["results"], 13) == %{
             "operation_id" => "different-guest",
             "status" => "rejected",
             "code" => "invalid_transfer"
           }

    assert submit(conn, [transfer("transfer-1", "source", "destination", 1_000, 2, 1)]) == %{
             "results" => [transfer_result]
           }

    assert group(conn, "source")["revision"] == 4
    assert group(conn, "destination")["revision"] == 2
  end

  test "reductions and chargebacks revise every group holding transferred payment cash", %{
    conn: conn
  } do
    response =
      submit(conn, [
        open_group("open-source", "source", [room("source-room", 10_000)]),
        cash_payment("pay-source", "source", 2_000, 1),
        open_group("open-destination", "destination", [room("destination-room", 10_000)]),
        transfer("transfer-1", "source", "destination", 2_000, 2, 1),
        reduce_payment("reduce-1", "pay-source", 500, 3),
        charge_back("chargeback-1", "pay-source", 4)
      ])

    assert Enum.at(response["results"], 4) == %{
             "operation_id" => "reduce-1",
             "status" => "applied",
             "payment_operation_id" => "pay-source",
             "group_id" => "source",
             "amount_cents" => 500,
             "outstanding_deposit_cents" => 2_000,
             "revision" => 4
           }

    assert Enum.at(response["results"], 5) == %{
             "operation_id" => "chargeback-1",
             "status" => "applied",
             "payment_operation_id" => "pay-source",
             "group_id" => "source",
             "charged_back_cents" => 1_500,
             "outstanding_deposit_cents" => 2_000,
             "revision" => 5
           }

    assert group(conn, "source")["revision"] == 5

    assert group(conn, "destination")
           |> Map.take(["revision", "cash_paid_cents", "outstanding_deposit_cents"]) == %{
             "revision" => 4,
             "cash_paid_cents" => 0,
             "outstanding_deposit_cents" => 2_000
           }

    assert payment(conn, "pay-source") == %{
             "payment_operation_id" => "pay-source",
             "original_group_id" => "source",
             "recorded_cents" => 2_000,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 500,
             "charged_back_cents" => 1_500,
             "held_by_group" => []
           }

    assert ledger(conn)
           |> Map.take(["cash_held_cents", "cash_reduced_cents", "cash_charged_back_cents"]) == %{
             "cash_held_cents" => 0,
             "cash_reduced_cents" => 500,
             "cash_charged_back_cents" => 1_500
           }
  end

  test "rejects transfers that exceed the destination's outstanding deposit", %{conn: conn} do
    response =
      submit(conn, [
        open_group("open-source", "source", [room("source-room", 10_000)]),
        cash_payment("pay-source", "source", 2_000, 1),
        open_group("open-destination", "destination", [room("destination-room", 10_000)]),
        cash_payment("pay-destination", "destination", 2_000, 1),
        transfer("exceeds-outstanding", "source", "destination", 1, 2, 2)
      ])

    assert Enum.at(response["results"], 4) == %{
             "operation_id" => "exceeds-outstanding",
             "status" => "rejected",
             "code" => "transfer_exceeds_outstanding"
           }

    assert group(conn, "source")["revision"] == 2
    assert group(conn, "destination")["revision"] == 2
    assert ledger(conn)["cash_held_cents"] == 4_000
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp group(conn, group_id) do
    conn
    |> get(~p"/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp payment(conn, payment_operation_id) do
    conn
    |> get(~p"/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get(~p"/api/v1/ledger?on=2027-01-10")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp room(room_id, nightly_rate_cents),
    do: %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}

  defp open_group(operation_id, group_id, rooms, guest_id \\ "guest-22") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2027-04-01",
      "departure_on" => "2027-04-02",
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

  defp apply_credit(operation_id, group_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp cancel_group(operation_id, group_id, expected_revision, refund_method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2027-01-03",
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
         source_expected_revision \\ nil,
         destination_expected_revision \\ nil
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2027-01-05",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
    |> maybe_put("expected_revision", source_expected_revision)
    |> maybe_put("destination_expected_revision", destination_expected_revision)
  end

  defp reduce_payment(operation_id, payment_operation_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-01-06",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp charge_back(operation_id, payment_operation_id, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-07",
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision
    }
  end

  defp maybe_put(operation, _key, nil), do: operation
  defp maybe_put(operation, key, value), do: Map.put(operation, key, value)
end
