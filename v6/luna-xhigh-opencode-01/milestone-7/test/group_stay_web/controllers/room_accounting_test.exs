defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{CreditAllocation, CreditLot, Group, Repo, Room}
  import Ecto.Query

  test "allocates funding by room and settles selected rooms", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} = submit(conn, [open_group("group-1")])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [payment("pay-1", "group-1", 6_000)])

    assert %{
             "data" => %{
               "deposit_due_cents" => 6_000,
               "deposit_paid_cents" => 6_000,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 2_000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 4_000}
               ]
             }
           } = get_group(conn, "group-1")

    assert %{
             "results" => [
               %{
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 4_000,
                 "revision" => 3
               }
             ]
           } = submit(conn, [cancel_rooms("cancel-1", ["room-b"])])

    assert %{
             "data" => %{
               "status" => "active",
               "deposit_due_cents" => 2_000,
               "deposit_paid_cents" => 2_000,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 2_000},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
               ]
             }
           } = get_group(conn, "group-1")
  end

  test "reduces and charges back a payment without rewriting its result", %{conn: conn} do
    submit(conn, [open_group("group-1")])

    assert %{"results" => [payment_result]} =
             submit(conn, [payment("pay-1", "group-1", 4_000)])

    assert %{"results" => [%{"amount_cents" => 1_000, "revision" => 3}]} =
             submit(conn, [reduce("reduce-1", "pay-1", 1_000)])

    assert %{
             "data" => %{
               "recorded_cents" => 4_000,
               "held_cents" => 3_000,
               "reduced_cents" => 1_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "charged_back_cents" => 0
             }
           } = get_payment(conn, "pay-1")

    assert %{"results" => [%{"charged_back_cents" => 3_000, "revision" => 4}]} =
             submit(conn, [chargeback("chargeback-1", "pay-1")])

    assert %{"data" => ^payment_result} = get_operation(conn, "pay-1")

    assert %{
             "data" => %{
               "held_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 3_000
             }
           } = get_payment(conn, "pay-1")
  end

  test "uses chargeback-specific rejection codes", %{conn: conn} do
    submit(conn, [open_group("group-1")])

    assert %{"results" => [%{"code" => "payment_not_chargeable"}]} =
             submit(conn, [chargeback("chargeback-open", "open-group-1")])

    assert %{"results" => [%{"code" => "operation_not_found"}]} =
             submit(conn, [chargeback("chargeback-missing", "missing-payment")])
  end

  test "reconciles a payment after conversion to credit", %{conn: conn} do
    submit(conn, [open_group("source")])
    submit(conn, [payment("pay-1", "source", 4_000)])

    assert %{"results" => [%{"credit_issued_cents" => 4_400}]} =
             submit(conn, [
               cancel("cancel-1", "source") |> Map.put("refund_method", "hotel_credit")
             ])

    assert %{
             "data" => %{
               "recorded_cents" => 4_000,
               "held_cents" => 0,
               "converted_to_credit_cents" => 4_000
             }
           } = get_payment(conn, "pay-1")
  end

  test "tracks a chargeback shortfall while credit is applied", %{conn: conn} do
    submit(conn, [open_group("source")])
    submit(conn, [payment("pay-1", "source", 4_000)])

    submit(conn, [cancel("cancel-1", "source") |> Map.put("refund_method", "hotel_credit")])

    target =
      open_group("target")
      |> Map.put("rooms", [%{"room_id" => "room-a", "nightly_rate_cents" => 11_000}])

    submit(conn, [target])

    assert %{"results" => [%{"amount_cents" => 2_200}]} =
             submit(conn, [
               %{
                 "operation_id" => "apply-1",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-10-02",
                 "group_id" => "target",
                 "amount_cents" => 2_200
               }
             ])

    assert %{"results" => [%{"charged_back_cents" => 4_000}]} =
             submit(conn, [chargeback("chargeback-1", "pay-1")])

    assert %{"data" => %{"credit_liability_cents" => 2_200, "credit_shortfall_cents" => 2_200}} =
             conn
             |> get("/api/v1/ledger")
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [cancel("cancel-target", "target")])

    assert %{"data" => %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0}} =
             conn
             |> get("/api/v1/ledger")
             |> json_response(200)
  end

  test "backfills legacy funding before any durable funding records", %{conn: conn} do
    submit(conn, [open_group("legacy")])

    lot_a =
      Repo.insert!(%CreditLot{
        guest_id: "guest-1",
        source_operation_id: "legacy-credit-a",
        remaining_cents: 0,
        issued_on: ~D[2026-01-01],
        expires_on: ~D[2027-01-01],
        unrecovered_clawback_cents: 0
      })

    lot_b =
      Repo.insert!(%CreditLot{
        guest_id: "guest-1",
        source_operation_id: "legacy-credit-b",
        remaining_cents: 0,
        issued_on: ~D[2026-02-01],
        expires_on: ~D[2027-02-02],
        unrecovered_clawback_cents: 0
      })

    Repo.insert!(%CreditAllocation{
      credit_lot_id: lot_a.id,
      group_id: "legacy",
      amount_cents: 1_000
    })

    Repo.insert!(%CreditAllocation{
      credit_lot_id: lot_b.id,
      group_id: "legacy",
      amount_cents: 2_000
    })

    Repo.update_all(
      from(group in Group, where: group.group_id == "legacy"),
      set: [
        deposit_paid_cents: 6_000,
        cash_paid_cents: 3_000,
        credit_paid_cents: 3_000,
        room_accounting_initialized: false
      ]
    )

    Repo.update_all(
      from(room in Room, where: room.group_id == "legacy"),
      set: [cash_paid_cents: 0, credit_paid_cents: 0]
    )

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 2_000, "credit_paid_cents" => 0},
                 %{
                   "room_id" => "room-b",
                   "cash_paid_cents" => 1_000,
                   "credit_paid_cents" => 3_000
                 }
               ]
             }
           } = get_group(conn, "legacy")

    assert %{"data" => %{"credit_liability_cents" => 3_000}} =
             conn
             |> get("/api/v1/ledger")
             |> json_response(200)
  end

  defp open_group(group_id) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => "property-1",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 20_000}
      ]
    }
  end

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id
    }
  end

  defp cancel_rooms(operation_id, room_ids) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => "2026-10-01",
      "group_id" => "group-1",
      "room_ids" => room_ids
    }
  end

  defp reduce(operation_id, payment_operation_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp chargeback(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id
    }
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp get_group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  defp get_operation(conn, operation_id) do
    conn
    |> get("/api/v1/operations/#{operation_id}")
    |> json_response(200)
  end

  defp get_payment(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
  end
end
