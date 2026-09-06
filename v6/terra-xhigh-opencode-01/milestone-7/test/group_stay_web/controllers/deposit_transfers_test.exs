defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: true

  test "moves cash in reverse allocation order and follows it through corrections", %{conn: conn} do
    conn =
      post_operations(conn, [
        open_operation("cash-source", rate_plan: "advance_purchase", rooms: rooms(100, 100)),
        open_operation("cash-destination",
          rate_plan: "advance_purchase",
          rooms: rooms(100, 100)
        ),
        cash_payment("cash-payment-a", "cash-source", 100, 1),
        cash_payment("cash-payment-b", "cash-source", 100, 2),
        transfer("cash-transfer", "cash-source", "cash-destination", 150, 3, 1)
      ])

    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"revision" => 3},
               %{
                 "status" => "applied",
                 "source_group_id" => "cash-source",
                 "destination_group_id" => "cash-destination",
                 "amount_cents" => 150,
                 "source_outstanding_deposit_cents" => 150,
                 "destination_outstanding_deposit_cents" => 50,
                 "source_revision" => 4,
                 "destination_revision" => 2
               } = transfer_result
             ]
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        transfer("cash-transfer", "cash-source", "cash-destination", 150, 3, 1)
      ])

    assert %{"results" => [^transfer_result]} = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/cash-source")

    assert %{
             "data" => %{
               "revision" => 4,
               "deposit_paid_cents" => 50,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 50},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/cash-destination")

    assert %{
             "data" => %{
               "revision" => 2,
               "deposit_paid_cents" => 150,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 100},
                 %{"room_id" => "room-b", "cash_paid_cents" => 50}
               ]
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/payments/cash-payment-a")

    assert %{
             "data" => %{
               "held_cents" => 100,
               "held_by_group" => [
                 %{"group_id" => "cash-destination", "amount_cents" => 50},
                 %{"group_id" => "cash-source", "amount_cents" => 50}
               ]
             }
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "reduce-cash-payment-a",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2027-01-03",
          "payment_operation_id" => "cash-payment-a",
          "amount_cents" => 75,
          "expected_revision" => 4
        },
        %{
          "operation_id" => "charge-back-cash-payment-b",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-01-03",
          "payment_operation_id" => "cash-payment-b",
          "expected_revision" => 5
        }
      ])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "outstanding_deposit_cents" => 175,
                 "revision" => 5
               },
               %{
                 "status" => "applied",
                 "charged_back_cents" => 100,
                 "outstanding_deposit_cents" => 175,
                 "revision" => 6
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/cash-destination")
    assert %{"data" => %{"revision" => 4, "deposit_paid_cents" => 0}} = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/payments/cash-payment-b")
    assert %{"data" => %{"held_cents" => 0, "held_by_group" => []}} = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 25,
               "cash_reduced_cents" => 75,
               "cash_charged_back_cents" => 100
             }
           } = json_response(conn, 200)
  end

  test "preserves hotel-credit provenance through a transfer and refundable settlement", %{
    conn: conn
  } do
    conn =
      post_operations(conn, [
        open_operation("credit-issuer", rooms: rooms(500)),
        open_operation("credit-source", rooms: rooms(500)),
        open_operation("credit-destination", rooms: rooms(500)),
        cash_payment("credit-issuer-payment", "credit-issuer", 100, 1),
        %{
          "operation_id" => "issue-transfer-credit",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "credit-issuer",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        },
        %{
          "operation_id" => "apply-transfer-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-03",
          "group_id" => "credit-source",
          "amount_cents" => 100,
          "expected_revision" => 1
        },
        transfer("credit-transfer", "credit-source", "credit-destination", 100, 2, 1),
        %{
          "operation_id" => "cancel-credit-destination",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-04",
          "group_id" => "credit-destination",
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 1},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"credit_issued_cents" => 110, "revision" => 3},
               %{"revision" => 2},
               %{
                 "source_outstanding_deposit_cents" => 100,
                 "destination_outstanding_deposit_cents" => 0,
                 "source_revision" => 3,
                 "destination_revision" => 2
               },
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/credit-source")

    assert %{"data" => %{"credit_paid_cents" => 0, "outstanding_deposit_cents" => 100}} =
             json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-01-04")

    assert %{
             "data" => %{
               "available_cents" => 110,
               "lots" => [
                 %{
                   "source_operation_id" => "issue-transfer-credit",
                   "remaining_cents" => 110,
                   "expires_on" => "2028-01-02"
                 }
               ]
             }
           } = json_response(conn, 200)
  end

  test "checks transfer existence and revisions before transfer rules", %{conn: conn} do
    conn =
      post_operations(conn, [
        open_operation("transfer-source", rooms: rooms(100, 100)),
        open_operation("transfer-destination", rooms: rooms(100)),
        transfer("missing-destination", "transfer-source", "missing", 1, 0, 1),
        transfer("stale-destination", "transfer-source", "transfer-destination", 1, 1, 0),
        transfer("invalid-amount", "transfer-source", "transfer-destination", 0, 1, 1),
        transfer("too-little-funding", "transfer-source", "transfer-destination", 1, 1, 1),
        cash_payment("transfer-source-payment", "transfer-source", 30, 1),
        transfer("destination-overflow", "transfer-source", "transfer-destination", 25, 2, 1),
        open_operation("other-transfer-guest", guest_id: "guest-99", rooms: rooms(100)),
        transfer("different-guest", "transfer-source", "other-transfer-guest", 1, 2, 1),
        %{
          "operation_id" => "cancel-transfer-destination",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-03",
          "group_id" => "transfer-destination",
          "expected_revision" => 1
        },
        transfer("inactive-destination", "transfer-source", "transfer-destination", 1, 2, 2)
      ])

    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 1},
               %{"status" => "rejected", "code" => "group_not_found", "group_id" => "missing"},
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "transfer-destination",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               },
               %{"status" => "rejected", "code" => "invalid_amount"},
               %{"status" => "rejected", "code" => "transfer_exceeds_held_funding"},
               %{"revision" => 2},
               %{"status" => "rejected", "code" => "transfer_exceeds_outstanding"},
               %{"revision" => 1},
               %{"status" => "rejected", "code" => "invalid_transfer"},
               %{"status" => "applied", "revision" => 2},
               %{
                 "status" => "rejected",
                 "code" => "group_not_active",
                 "group_id" => "transfer-destination"
               }
             ]
           } = json_response(conn, 200)
  end

  test "draws newer credit before older cash and fills destination rooms in order", %{conn: conn} do
    conn =
      post_operations(conn, [
        open_operation("mixed-issuer", rooms: rooms(500)),
        open_operation("mixed-source", rooms: rooms(500, 500)),
        open_operation("mixed-destination", rooms: rooms(500, 500)),
        cash_payment("mixed-issuer-payment", "mixed-issuer", 100, 1),
        %{
          "operation_id" => "mixed-issue-credit",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "mixed-issuer",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        },
        cash_payment("mixed-cash", "mixed-source", 100, 1),
        %{
          "operation_id" => "mixed-apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-03",
          "group_id" => "mixed-source",
          "amount_cents" => 100,
          "expected_revision" => 2
        },
        transfer("mixed-transfer", "mixed-source", "mixed-destination", 150, 3, 1)
      ])

    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 1},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"credit_issued_cents" => 110, "revision" => 3},
               %{"revision" => 2},
               %{"revision" => 3},
               %{
                 "source_outstanding_deposit_cents" => 150,
                 "destination_outstanding_deposit_cents" => 50,
                 "source_revision" => 4,
                 "destination_revision" => 2
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/mixed-destination")

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 0, "credit_paid_cents" => 100},
                 %{"room_id" => "room-b", "cash_paid_cents" => 50, "credit_paid_cents" => 0}
               ]
             }
           } = json_response(conn, 200)
  end

  defp post_operations(conn, operations) do
    post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  defp open_operation(group_id, overrides) do
    operation = %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-03-05",
      "departure_on" => "2027-03-06",
      "rate_plan" => "flexible",
      "rooms" => rooms(100)
    }

    Enum.reduce(overrides, operation, fn {key, value}, operation ->
      Map.put(operation, Atom.to_string(key), value)
    end)
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
      "occurred_on" => "2027-01-03",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => source_revision,
      "destination_expected_revision" => destination_revision
    }
  end

  defp rooms(first_rate, second_rate \\ nil) do
    [%{"room_id" => "room-a", "nightly_rate_cents" => first_rate}]
    |> then(fn rooms ->
      if second_rate,
        do: rooms ++ [%{"room_id" => "room-b", "nightly_rate_cents" => second_rate}],
        else: rooms
    end)
  end
end
