defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.{
    CashAllocation,
    CreditAllocation,
    CreditLot,
    Group,
    GroupRoom,
    Ledger,
    OperationRecord,
    PaymentDisposition,
    Repo
  }

  import Ecto.Query

  defp open_operation(group_id, operation_id \\ "open-1", overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
        ]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  test "allocates funding by room and settles only selected rooms", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open_operation("group-1"),
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-1",
                 "amount_cents" => 7_000
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/groups/group-1"), 200)["data"] == %{
             "group_id" => "group-1",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "status" => "active",
             "revision" => 2,
             "rooms" => [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "lodging_total_cents" => 30_000,
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 6_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "lodging_total_cents" => 30_000,
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 1_000,
                 "credit_paid_cents" => 0
               }
             ],
             "lodging_total_cents" => 60_000,
             "deposit_due_cents" => 12_000,
             "deposit_paid_cents" => 7_000,
             "cash_paid_cents" => 7_000,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 5_000
           }

    cancellation =
      post_batch(conn, [
        %{
          "operation_id" => "cancel-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-1",
          "room_ids" => ["room-b"]
        }
      ])
      |> json_response(200)

    assert cancellation == %{
             "results" => [
               %{
                 "operation_id" => "cancel-rooms",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 1_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           }

    group = json_response(get(conn, "/api/v1/groups/group-1"), 200)["data"]
    assert group["status"] == "active"
    assert group["deposit_due_cents"] == 6_000
    assert group["cash_paid_cents"] == 6_000
    assert group["outstanding_deposit_cents"] == 0
    assert Enum.map(group["rooms"], & &1["status"]) == ["active", "cancelled"]

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"]
           |> Map.take(["cash_held_cents", "cash_refunded_cents"]) == %{
             "cash_held_cents" => 6_000,
             "cash_refunded_cents" => 1_000
           }
  end

  test "reduces held cash in reverse allocation order and reconciles the payment", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open_operation("group-2"),
               %{
                 "operation_id" => "pay-2",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-2",
                 "amount_cents" => 7_000
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 3, "amount_cents" => 1_500}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "reduce-2",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-05",
                 "payment_operation_id" => "pay-2",
                 "amount_cents" => 1_500,
                 "expected_revision" => 2
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/payments/pay-2"), 200)["data"] == %{
             "payment_operation_id" => "pay-2",
             "original_group_id" => "group-2",
             "recorded_cents" => 7_000,
             "held_cents" => 5_500,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 1_500,
             "charged_back_cents" => 0
           }

    group = json_response(get(conn, "/api/v1/groups/group-2"), 200)["data"]
    assert group["outstanding_deposit_cents"] == 6_500
    assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [5_500, 0]
  end

  test "chargeback reclassifies refunded cash and preserves reduced cash", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open_operation("group-3"),
               %{
                 "operation_id" => "pay-3",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-3",
                 "amount_cents" => 7_000
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 3, "refunded_cents" => 1_000}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "cancel-3",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "group-3",
                 "room_ids" => ["room-b"]
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 4, "charged_back_cents" => 7_000}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "chargeback-3",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-06",
                 "payment_operation_id" => "pay-3",
                 "expected_revision" => 3
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/payments/pay-3"), 200)["data"] == %{
             "payment_operation_id" => "pay-3",
             "original_group_id" => "group-3",
             "recorded_cents" => 7_000,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 7_000
           }

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"]
           |> Map.take(["cash_held_cents", "cash_refunded_cents", "cash_charged_back_cents"]) ==
             %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_charged_back_cents" => 7_000
             }
  end

  test "payment reconciliation distinguishes missing and non-payment operations", %{conn: conn} do
    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "rejected-op",
                 "type" => "unknown",
                 "occurred_on" => "2026-10-04"
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/payments/missing"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert json_response(get(conn, "/api/v1/payments/rejected-op"), 422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }
  end

  test "payment reconciliation does not persist a reconstructed disposition", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open_operation("read-only-payment", "read-only-open"),
               %{
                 "operation_id" => "read-only-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "read-only-payment",
                 "amount_cents" => 1_000
               }
             ])
             |> json_response(200)

    Repo.delete_all(PaymentDisposition)

    assert json_response(get(conn, "/api/v1/payments/read-only-pay"), 200)["data"] == %{
             "payment_operation_id" => "read-only-pay",
             "original_group_id" => "read-only-payment",
             "recorded_cents" => 1_000,
             "held_cents" => 1_000,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }

    assert Repo.get(PaymentDisposition, "read-only-pay") == nil
  end

  test "chargeback creates a credit shortfall that restoration absorbs", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_batch(conn, [
               open_operation("source", "source-open", %{"guest_id" => "guest-credit"}),
               %{
                 "operation_id" => "source-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "source",
                 "amount_cents" => 1_000
               },
               %{
                 "operation_id" => "source-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "source",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open_operation("target", "target-open", %{"guest_id" => "guest-credit"}),
               %{
                 "operation_id" => "target-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-10-06",
                 "group_id" => "target",
                 "amount_cents" => 1_000
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 4, "charged_back_cents" => 1_000}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "source-chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-07",
                 "payment_operation_id" => "source-pay",
                 "expected_revision" => 3
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"]
           |> Map.take(["credit_liability_cents", "credit_shortfall_cents"]) == %{
             "credit_liability_cents" => 1_000,
             "credit_shortfall_cents" => 1_000
           }

    assert %{"results" => [%{"revision" => 3}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "target-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-08",
                 "group_id" => "target",
                 "expected_revision" => 2
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"]
           |> Map.take(["credit_liability_cents", "credit_shortfall_cents"]) == %{
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  test "hydrates legacy funding before durable funding in commit order", %{conn: conn} do
    booked_on = ~D[2026-10-03]
    arrival_on = ~D[2026-12-10]

    Repo.insert!(%Group{
      group_id: "legacy",
      guest_id: "legacy-guest",
      property_id: "ams-canal",
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: ~D[2026-12-13],
      rate_plan: "flexible",
      policy_version: "flex-14",
      refundable_until: ~D[2026-11-26],
      status: "active",
      revision: 1,
      lodging_total_cents: 60_000,
      deposit_due_cents: 12_000,
      deposit_paid_cents: 12_000,
      cash_paid_cents: 8_000,
      credit_paid_cents: 4_000
    })

    for {room_id, position} <- [{"room-a", 0}, {"room-b", 1}] do
      Repo.insert!(%GroupRoom{
        group_id: "legacy",
        room_id: room_id,
        position: position,
        nightly_rate_cents: 10_000,
        lodging_total_cents: 30_000,
        deposit_due_cents: 6_000,
        status: "active",
        cash_paid_cents: 0,
        credit_paid_cents: 0
      })
    end

    lot =
      Repo.insert!(%CreditLot{
        guest_id: "legacy-guest",
        source_operation_id: "legacy-credit-source",
        remaining_cents: 0,
        expires_on: ~D[2028-01-01]
      })

    Repo.insert!(%CreditAllocation{
      group_id: "legacy",
      credit_lot_id: lot.id,
      amount_cents: 4_000
    })

    Repo.update!(Ecto.Changeset.change(Repo.get!(Ledger, 1), %{cash_held_cents: 8_000}))

    Repo.insert!(%OperationRecord{
      operation_id: "durable-pay",
      type: "record_cash_payment",
      payload: "{}",
      result:
        Jason.encode!(%{
          operation_id: "durable-pay",
          status: "applied",
          group_id: "legacy",
          amount_cents: 2_000
        })
    })

    Repo.insert!(%OperationRecord{
      operation_id: "durable-credit",
      type: "apply_hotel_credit",
      payload: "{}",
      result:
        Jason.encode!(%{
          operation_id: "durable-credit",
          status: "applied",
          group_id: "legacy",
          amount_cents: 2_000
        })
    })

    assert json_response(
             post_batch(conn, [
               %{
                 "operation_id" => "stale-legacy-reduction",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "payment_operation_id" => "durable-pay",
                 "amount_cents" => 100,
                 "expected_revision" => 0
               }
             ]),
             200
           ) == %{
             "results" => [
               %{
                 "operation_id" => "stale-legacy-reduction",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "legacy",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           }

    assert Repo.get(PaymentDisposition, "durable-pay") == nil
    assert Repo.all(CashAllocation) == []

    group = json_response(get(conn, "/api/v1/groups/legacy"), 200)["data"]

    assert Enum.map(group["rooms"], &Map.take(&1, ["cash_paid_cents", "credit_paid_cents"])) == [
             %{"cash_paid_cents" => 6_000, "credit_paid_cents" => 0},
             %{"cash_paid_cents" => 2_000, "credit_paid_cents" => 4_000}
           ]

    assert Repo.all(
             from allocation in CashAllocation,
               where: allocation.group_id == "legacy",
               order_by: allocation.id,
               select: {allocation.payment_operation_id, allocation.amount_cents}
           ) == [
             {nil, 6_000},
             {"durable-pay", 2_000}
           ]

    assert Repo.all(
             from allocation in CreditAllocation,
               where: allocation.group_id == "legacy",
               order_by: allocation.id,
               select: {allocation.source_operation_id, allocation.amount_cents}
           ) == [
             {nil, 2_000},
             {"durable-credit", 2_000}
           ]
  end
end
