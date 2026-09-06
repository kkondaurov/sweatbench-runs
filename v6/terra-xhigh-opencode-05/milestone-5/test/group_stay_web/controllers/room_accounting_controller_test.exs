defmodule GroupStayWeb.RoomAccountingControllerTest do
  use GroupStayWeb.ConnCase, async: false

  test "allocates funding by room, settles selected rooms, and leaves remaining rooms active", %{
    conn: conn
  } do
    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             post_batch(conn, [
               two_room_group("open-1", "group-1"),
               cash_payment("pay-1", "group-1", 30)
             ])
             |> json_response(200)

    assert %{
             "data" => %{
               "deposit_due_cents" => 60,
               "cash_paid_cents" => 30,
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "status" => "active",
                   "lodging_total_cents" => 100,
                   "deposit_due_cents" => 20,
                   "cash_paid_cents" => 20,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "status" => "active",
                   "lodging_total_cents" => 200,
                   "deposit_due_cents" => 40,
                   "cash_paid_cents" => 10,
                   "credit_paid_cents" => 0
                 }
               ]
             }
           } = get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

    cancellation = %{
      "operation_id" => "cancel-room-b",
      "type" => "cancel_rooms",
      "occurred_on" => "2027-01-15",
      "group_id" => "group-1",
      "room_ids" => ["room-b"]
    }

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 10,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } = post_batch(build_conn(), [cancellation]) |> json_response(200)

    assert %{
             "data" => %{
               "status" => "active",
               "lodging_total_cents" => 100,
               "deposit_due_cents" => 20,
               "deposit_paid_cents" => 20,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 20},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
               ]
             }
           } = get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 20,
               "cash_refunded_cents" => 10,
               "cash_retained_cents" => 0
             }
           } = get(build_conn(), "/api/v1/ledger") |> json_response(200)

    assert %{"results" => [%{"status" => "applied", "refunded_cents" => 20, "revision" => 4}]} =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "cancel-rest",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-16",
                 "group_id" => "group-1"
               }
             ])
             |> json_response(200)
  end

  test "validates selected rooms and returns cancelled room identifiers in booking order", %{
    conn: conn
  } do
    post_batch(conn, [two_room_group("open-1", "group-1")])

    assert %{
             "results" => [
               %{
                 "status" => "rejected",
                 "code" => "invalid_rooms",
                 "group_id" => "group-1"
               }
             ]
           } =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "bad-cancel",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2027-01-15",
                 "group_id" => "group-1",
                 "room_ids" => ["room-a", "room-a"]
               }
             ])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-a", "room-b"],
                 "revision" => 2
               }
             ]
           } =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "ordered-cancel",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2027-01-15",
                 "group_id" => "group-1",
                 "room_ids" => ["room-b", "room-a"]
               }
             ])
             |> json_response(200)
  end

  test "reduces only held cash from the named payment and keeps its durable result", %{conn: conn} do
    post_batch(conn, [two_room_group("open-1", "group-1"), cash_payment("pay-1", "group-1", 30)])

    reduction = %{
      "operation_id" => "reduce-1",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay-1",
      "amount_cents" => 10,
      "expected_revision" => 2
    }

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "payment_operation_id" => "pay-1",
                 "group_id" => "group-1",
                 "amount_cents" => 10,
                 "outstanding_deposit_cents" => 40,
                 "revision" => 3
               }
             ]
           } = post_batch(build_conn(), [reduction]) |> json_response(200)

    assert %{
             "data" => %{
               "payment_operation_id" => "pay-1",
               "original_group_id" => "group-1",
               "recorded_cents" => 30,
               "held_cents" => 20,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 10,
               "charged_back_cents" => 0
             }
           } = get(build_conn(), "/api/v1/payments/pay-1") |> json_response(200)

    assert %{"data" => %{"cash_held_cents" => 20, "cash_reduced_cents" => 10}} =
             get(build_conn(), "/api/v1/ledger") |> json_response(200)

    assert %{"results" => [original]} =
             post_batch(build_conn(), [reduction]) |> json_response(200)

    assert original["revision"] == 3

    assert %{"results" => [%{"code" => "reduction_exceeds_held_cash"}]} =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "reduce-again",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay-1",
                 "amount_cents" => 21
               }
             ])
             |> json_response(200)
  end

  test "chargebacks revoke credit entitlement and restored credit first absorbs the shortfall", %{
    conn: conn
  } do
    source = one_room_group("open-source", "source", "credit-guest", 500)
    target = one_room_group("open-target", "target", "credit-guest", 550)

    assert %{"results" => results} =
             post_batch(conn, [
               source,
               cash_payment("pay-1", "source", 50),
               cash_payment("pay-2", "source", 50),
               %{
                 "operation_id" => "cancel-source",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-15",
                 "group_id" => "source",
                 "refund_method" => "hotel_credit"
               },
               target,
               %{
                 "operation_id" => "apply-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-16",
                 "group_id" => "target",
                 "amount_cents" => 110
               }
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "payment_operation_id" => "pay-1",
                 "group_id" => "source",
                 "charged_back_cents" => 50,
                 "revision" => 5
               }
             ]
           } =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "chargeback-1",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay-1",
                 "expected_revision" => 4
               }
             ])
             |> json_response(200)

    assert %{
             "data" => %{
               "recorded_cents" => 50,
               "held_cents" => 0,
               "converted_to_credit_cents" => 0,
               "charged_back_cents" => 50
             }
           } = get(build_conn(), "/api/v1/payments/pay-1") |> json_response(200)

    assert %{
             "data" => %{
               "cash_charged_back_cents" => 50,
               "credit_liability_cents" => 110,
               "credit_shortfall_cents" => 55
             }
           } = get(build_conn(), "/api/v1/ledger") |> json_response(200)

    assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 110}} =
             get(build_conn(), "/api/v1/groups/target") |> json_response(200)

    assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "cancel-target",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-17",
                 "group_id" => "target"
               }
             ])
             |> json_response(200)

    assert %{
             "data" => %{
               "available_cents" => 55,
               "lots" => [%{"source_operation_id" => "cancel-source", "remaining_cents" => 55}]
             }
           } =
             get(build_conn(), "/api/v1/guests/credit-guest/credit?on=2027-01-17")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 55, "credit_shortfall_cents" => 0}} =
             get(build_conn(), "/api/v1/ledger?on=2027-01-17") |> json_response(200)
  end

  test "payment read distinguishes unknown and non-payment operations", %{conn: conn} do
    post_batch(conn, [two_room_group("open-1", "group-1")])

    assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
             get(build_conn(), "/api/v1/payments/open-1") |> json_response(422)

    assert %{"error" => %{"code" => "operation_not_found"}} =
             get(build_conn(), "/api/v1/payments/not-here") |> json_response(404)
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{operations: operations})

  defp two_room_group(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-04-01",
      "departure_on" => "2027-04-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 100},
        %{"room_id" => "room-b", "nightly_rate_cents" => 200}
      ]
    }
  end

  defp one_room_group(operation_id, group_id, guest_id, nightly_rate_cents) do
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
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => nightly_rate_cents}]
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
