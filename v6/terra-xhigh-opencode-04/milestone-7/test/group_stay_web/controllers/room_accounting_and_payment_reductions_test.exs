defmodule GroupStayWeb.RoomAccountingAndPaymentReductionsTest do
  use GroupStayWeb.ConnCase, async: false

  test "allocates funding by room and settles only selected rooms", %{conn: conn} do
    response =
      submit(conn, [
        open_group("open-1", "group-1", [room("room-a", 10_000), room("room-b", 20_000)]),
        cash_payment("pay-1", "group-1", 3_000, 1),
        cancel_rooms("cancel-b", "group-1", ["room-b"], 2)
      ])

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "cancel-b",
             "status" => "applied",
             "group_id" => "group-1",
             "cancelled_room_ids" => ["room-b"],
             "refunded_cents" => 1_000,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert group(conn, "group-1")
           |> Map.take([
             "status",
             "lodging_total_cents",
             "deposit_due_cents",
             "deposit_paid_cents",
             "cash_paid_cents",
             "outstanding_deposit_cents",
             "rooms"
           ]) == %{
             "status" => "active",
             "lodging_total_cents" => 10_000,
             "deposit_due_cents" => 2_000,
             "deposit_paid_cents" => 2_000,
             "cash_paid_cents" => 2_000,
             "outstanding_deposit_cents" => 0,
             "rooms" => [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "lodging_total_cents" => 10_000,
                 "deposit_due_cents" => 2_000,
                 "cash_paid_cents" => 2_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 20_000,
                 "status" => "cancelled",
                 "lodging_total_cents" => 20_000,
                 "deposit_due_cents" => 4_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]
           }

    assert ledger(conn) == %{
             "cash_held_cents" => 2_000,
             "cash_refunded_cents" => 1_000,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    assert submit(conn, [cancel_rooms("duplicate", "group-1", ["room-a", "room-a"], 3)]) == %{
             "results" => [
               %{"operation_id" => "duplicate", "status" => "rejected", "code" => "invalid_rooms"}
             ]
           }
  end

  test "calculates one hotel-credit bonus across selected rooms", %{conn: conn} do
    response =
      submit(conn, [
        open_group("open-1", "group-1", [room("room-a", 25), room("room-b", 25)]),
        cash_payment("pay-1", "group-1", 2, 1),
        cash_payment("pay-2", "group-1", 3, 2),
        cancel_rooms("cancel-a", "group-1", ["room-a"], 3, "hotel_credit")
      ])

    assert Enum.at(response["results"], 3) == %{
             "operation_id" => "cancel-a",
             "status" => "applied",
             "group_id" => "group-1",
             "cancelled_room_ids" => ["room-a"],
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 6,
             "revision" => 4
           }

    assert credit(conn) == %{
             "guest_id" => "guest-22",
             "available_cents" => 6,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-a",
                 "remaining_cents" => 6,
                 "expires_on" => "2028-02-03"
               }
             ]
           }
  end

  test "reduces held payment allocations in reverse fill order and reconciles the payment", %{
    conn: conn
  } do
    response =
      submit(conn, [
        open_group("open-1", "group-1", [room("room-a", 10_000), room("room-b", 10_000)]),
        cash_payment("pay-1", "group-1", 3_000, 1),
        reduce_payment("reduce-1", "pay-1", 1_500, 2),
        reduce_payment("too-large", "pay-1", 1_501, 3),
        reduce_payment("reduce-2", "pay-1", 1_500, 3)
      ])

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "reduce-1",
             "status" => "applied",
             "payment_operation_id" => "pay-1",
             "group_id" => "group-1",
             "amount_cents" => 1_500,
             "outstanding_deposit_cents" => 2_500,
             "revision" => 3
           }

    assert Enum.at(response["results"], 3) == %{
             "operation_id" => "too-large",
             "status" => "rejected",
             "code" => "reduction_exceeds_held_cash"
           }

    assert Enum.at(response["results"], 4)["outstanding_deposit_cents"] == 4_000

    assert payment(conn, "pay-1") == %{
             "payment_operation_id" => "pay-1",
             "original_group_id" => "group-1",
             "recorded_cents" => 3_000,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 3_000,
             "charged_back_cents" => 0
           }

    assert ledger(conn)["cash_reduced_cents"] == 3_000

    assert submit(conn, [reduce_payment("reduce-1", "pay-1", 1_500, 2)]) == %{
             "results" => [Enum.at(response["results"], 2)]
           }

    assert group(conn, "group-1")["revision"] == 4

    assert submit(conn, [reduce_payment("not-reducible", "pay-1", 1, 4)]) == %{
             "results" => [
               %{
                 "operation_id" => "not-reducible",
                 "status" => "rejected",
                 "code" => "payment_not_reducible"
               }
             ]
           }
  end

  test "charges back converted cash, preserves funded-group revision, and clears a restored shortfall",
       %{
         conn: conn
       } do
    response =
      submit(conn, [
        open_group("open-source", "source", [room("source-room", 10_000)]),
        cash_payment("pay-source", "source", 2_000, 1),
        cancel_group("cancel-source", "source", 2, "hotel_credit"),
        open_group("open-target", "target", [room("target-room", 10_000)]),
        apply_credit("apply-target", "target", 2_000, 1),
        charge_back("chargeback", "pay-source", 3)
      ])

    assert Enum.at(response["results"], 5) == %{
             "operation_id" => "chargeback",
             "status" => "applied",
             "payment_operation_id" => "pay-source",
             "group_id" => "source",
             "charged_back_cents" => 2_000,
             "outstanding_deposit_cents" => 0,
             "revision" => 4
           }

    assert group(conn, "target")["revision"] == 2

    assert payment(conn, "pay-source") == %{
             "payment_operation_id" => "pay-source",
             "original_group_id" => "source",
             "recorded_cents" => 2_000,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 2_000
           }

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 2_000,
             "credit_liability_cents" => 2_000,
             "credit_shortfall_cents" => 2_000
           }

    assert submit(conn, [cancel_group("cancel-target", "target", 2)])
           |> get_in(["results", Access.at(0)]) ==
             %{
               "operation_id" => "cancel-target",
               "status" => "applied",
               "group_id" => "target",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

    assert ledger(conn)["credit_liability_cents"] == 0
    assert ledger(conn)["credit_shortfall_cents"] == 0
  end

  test "returns documented reconciliation errors", %{conn: conn} do
    assert conn |> get(~p"/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    submit(conn, [open_group("open-1", "group-1", [room("room-a", 10_000)])])

    assert conn |> get(~p"/api/v1/payments/open-1") |> json_response(422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }
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

  defp credit(conn) do
    conn
    |> get(~p"/api/v1/guests/guest-22/credit?on=2027-02-02")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get(~p"/api/v1/ledger?on=2027-02-02")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp payment(conn, payment_operation_id) do
    conn
    |> get(~p"/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp room(room_id, nightly_rate_cents),
    do: %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}

  defp open_group(operation_id, group_id, rooms) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-22",
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

  defp cancel_rooms(operation_id, group_id, room_ids, expected_revision, refund_method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => "2027-02-02",
      "group_id" => group_id,
      "room_ids" => room_ids,
      "expected_revision" => expected_revision,
      "refund_method" => refund_method
    }
  end

  defp reduce_payment(operation_id, payment_operation_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-02-02",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp cancel_group(operation_id, group_id, expected_revision, refund_method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2027-02-02",
      "group_id" => group_id,
      "expected_revision" => expected_revision,
      "refund_method" => refund_method
    }
  end

  defp apply_credit(operation_id, group_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-02-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp charge_back(operation_id, payment_operation_id, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2027-02-03",
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision
    }
  end
end
