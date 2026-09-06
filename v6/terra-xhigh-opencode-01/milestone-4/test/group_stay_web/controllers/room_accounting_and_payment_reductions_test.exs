defmodule GroupStayWeb.RoomAccountingAndPaymentReductionsTest do
  use GroupStayWeb.ConnCase, async: true

  test "allocates funding by room, settles selected rooms, and calculates one credit bonus", %{
    conn: conn
  } do
    conn = post_operations(conn, [open_operation("room-settlement", rooms: rooms(25, 25))])

    assert %{"results" => [%{"revision" => 1, "deposit_due_cents" => 10}]} =
             json_response(conn, 200)

    conn =
      post_operations(conn, [
        cash_payment("room-payment", "room-settlement", 10, 1),
        %{
          "operation_id" => "cancel-room-block",
          "type" => "cancel_rooms",
          "occurred_on" => "2027-01-02",
          "group_id" => "room-settlement",
          "room_ids" => ["room-b", "room-a"],
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"revision" => 2},
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-a", "room-b"],
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 11,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/room-settlement")

    assert %{
             "data" => %{
               "status" => "cancelled",
               "lodging_total_cents" => 0,
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "status" => "cancelled",
                   "lodging_total_cents" => 25,
                   "deposit_due_cents" => 5,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "status" => "cancelled",
                   "deposit_due_cents" => 5,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ]
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-01-02")
    assert %{"data" => %{"available_cents" => 11}} = json_response(conn, 200)
  end

  test "cancelling one room preserves the other room's funding until full cancellation", %{
    conn: conn
  } do
    conn = post_operations(conn, [open_operation("partial-cancellation", rooms: rooms(100, 100))])
    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        cash_payment("partial-cash", "partial-cancellation", 30, 1),
        %{
          "operation_id" => "cancel-second-room",
          "type" => "cancel_rooms",
          "occurred_on" => "2027-01-02",
          "group_id" => "partial-cancellation",
          "room_ids" => ["room-b"],
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"revision" => 2},
               %{
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 10,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/partial-cancellation")

    assert %{
             "data" => %{
               "status" => "active",
               "lodging_total_cents" => 100,
               "deposit_due_cents" => 20,
               "deposit_paid_cents" => 20,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 20},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
               ]
             }
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "cancel-duplicate-room",
          "type" => "cancel_rooms",
          "occurred_on" => "2027-01-02",
          "group_id" => "partial-cancellation",
          "room_ids" => ["room-a", "room-a"],
          "expected_revision" => 3
        }
      ])

    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rooms"}]} =
             json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "cancel-remaining-room",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "partial-cancellation",
          "expected_revision" => 3
        }
      ])

    assert %{"results" => [%{"refunded_cents" => 20, "revision" => 4}]} = json_response(conn, 200)
  end

  test "reduces only held funding in reverse fill order and reconciles its payment", %{conn: conn} do
    conn =
      post_operations(conn, [
        open_operation("reduction", rate_plan: "advance_purchase", rooms: rooms(100, 100))
      ])

    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        cash_payment("reducible-payment", "reduction", 150, 1),
        %{
          "operation_id" => "reduce-payment",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2027-01-03",
          "payment_operation_id" => "reducible-payment",
          "amount_cents" => 60,
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"revision" => 2},
               %{
                 "status" => "applied",
                 "payment_operation_id" => "reducible-payment",
                 "group_id" => "reduction",
                 "amount_cents" => 60,
                 "outstanding_deposit_cents" => 110,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/reduction")

    assert %{
             "data" => %{
               "deposit_paid_cents" => 90,
               "outstanding_deposit_cents" => 110,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 90},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/payments/reducible-payment")

    assert %{
             "data" => %{
               "payment_operation_id" => "reducible-payment",
               "original_group_id" => "reduction",
               "recorded_cents" => 150,
               "held_cents" => 90,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 60,
               "charged_back_cents" => 0
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger")

    assert %{"data" => %{"cash_held_cents" => 90, "cash_reduced_cents" => 60}} =
             json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "reduce-payment",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2027-01-03",
          "payment_operation_id" => "reducible-payment",
          "amount_cents" => 60,
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "outstanding_deposit_cents" => 110,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "reduce-too-much",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2027-01-03",
          "payment_operation_id" => "reducible-payment",
          "amount_cents" => 91,
          "expected_revision" => 3
        }
      ])

    assert %{"results" => [%{"status" => "rejected", "code" => "reduction_exceeds_held_cash"}]} =
             json_response(conn, 200)
  end

  test "chargeback revokes available credit first and tracks an active-credit shortfall", %{
    conn: conn
  } do
    conn = post_operations(conn, [open_operation("chargeback-source", rooms: rooms(500))])
    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        cash_payment("chargeback-payment", "chargeback-source", 100, 1),
        %{
          "operation_id" => "convert-chargeback-payment",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "chargeback-source",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        },
        open_operation("credit-consumer", rooms: rooms(550))
      ])

    assert %{
             "results" => [
               %{"revision" => 2},
               %{"credit_issued_cents" => 110, "revision" => 3},
               %{"revision" => 1}
             ]
           } =
             json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/chargeback-source")
    assert %{"data" => %{"revision" => 3}} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "apply-chargeback-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-03",
          "group_id" => "credit-consumer",
          "amount_cents" => 110,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "charge-back-payment",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-01-04",
          "payment_operation_id" => "chargeback-payment",
          "expected_revision" => 3
        }
      ])

    assert %{
             "results" => [
               %{"revision" => 2},
               %{
                 "status" => "applied",
                 "payment_operation_id" => "chargeback-payment",
                 "group_id" => "chargeback-source",
                 "charged_back_cents" => 100,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 4
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger?on=2027-01-04")

    assert %{
             "data" => %{
               "cash_charged_back_cents" => 100,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 110,
               "credit_shortfall_cents" => 110
             }
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "restore-shortfalled-credit",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-04",
          "group_id" => "credit-consumer",
          "expected_revision" => 2
        }
      ])

    assert %{"results" => [%{"status" => "applied", "revision" => 3}]} = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger?on=2027-01-04")

    assert %{"data" => %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0}} =
             json_response(conn, 200)
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

  defp rooms(first_rate, second_rate \\ nil) do
    [%{"room_id" => "room-a", "nightly_rate_cents" => first_rate}]
    |> then(fn rooms ->
      if second_rate,
        do: rooms ++ [%{"room_id" => "room-b", "nightly_rate_cents" => second_rate}],
        else: rooms
    end)
  end
end
