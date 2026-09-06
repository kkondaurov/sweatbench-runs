defmodule GroupStayWeb.Controllers.AccountingEdgesTest do
  use GroupStayWeb.ConnCase, async: true

  alias GroupStay.Credit.Application
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Ledger.Entry
  alias GroupStay.Repo

  @occurred_on "2026-10-03"

  test "reduce accepts expected_revision on the happy path and computes outstanding after", %{
    conn: conn
  } do
    conn =
      post_operations(conn, [
        open_group_operation(),
        record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5_000}),
        %{
          "operation_id" => "op-reduce",
          "type" => "reduce_cash_payment",
          "occurred_on" => @occurred_on,
          "payment_operation_id" => "op-pay",
          "amount_cents" => 2_000,
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               _,
               _,
               %{"status" => "applied", "revision" => 3, "outstanding_deposit_cents" => 16_500}
             ]
           } =
             json_response(conn, 200)
  end

  test "chargeback of a payment converted into a lot whose expiry passed still revokes", %{
    conn: conn
  } do
    conn =
      post_operations(conn, [
        open_group_operation(),
        record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
        cancel_operation(%{
          "operation_id" => "op-cancel",
          "occurred_on" => "2025-11-20",
          "refund_method" => "hotel_credit"
        }),
        charge_back_operation(%{"operation_id" => "op-cb"})
      ])

    assert %{"results" => [_, _, _, %{"status" => "applied", "charged_back_cents" => 10_000}]} =
             json_response(conn, 200)

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-20"), 200)

    assert %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0} = ledger(conn)
  end

  test "reduce, then room settlement, then chargeback keeps dispositions consistent", %{
    conn: conn
  } do
    conn =
      post_operations(conn, [
        open_group_operation(),
        record_payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10_000}),
        reduce_operation(%{"operation_id" => "op-reduce", "amount_cents" => 3_000}),
        cancel_operation(%{"occurred_on" => "2026-11-27"}),
        charge_back_operation(%{"operation_id" => "op-cb"})
      ])

    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    # recorded 10_000 = reduced 3_000 + charged_back 7_000 (retained 7_000 was
    # reclassified by the chargeback).
    assert %{"data" => statement} = json_response(get(conn, "/api/v1/payments/op-pay"), 200)

    assert %{
             "recorded_cents" => 10_000,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 3_000,
             "charged_back_cents" => 7_000
           } = statement

    assert %{
             "cash_retained_cents" => 0,
             "cash_reduced_cents" => 3_000,
             "cash_charged_back_cents" => 7_000,
             "cash_held_cents" => 0
           } = ledger(conn)
  end

  test "the senior block funds rooms before durable credit after a durable payment", %{conn: conn} do
    conn = post_operations(conn, [open_group_operation(%{"operation_id" => "op-o"})])
    group = Repo.get_by!(Group, group_id: "group-81")

    Repo.insert!(%Entry{
      group_id: group.id,
      type: "cash_held",
      amount_cents: 4_000,
      occurred_on: ~D[2026-01-05],
      operation_id: "legacy-pay"
    })

    lot =
      Repo.insert!(%Lot{
        guest_id: "guest-22",
        source_operation_id: "legacy-lot",
        remaining_cents: 5_000,
        expires_on: ~D[2028-01-06]
      })

    Repo.insert!(%Application{
      group_id: group.id,
      lot_id: lot.id,
      amount_cents: 5_000,
      operation_id: nil,
      room_id: nil
    })

    # Durable credit arrives after the senior block: room-a already holds the
    # legacy cash (4_000) and the legacy credit application filled room-a's
    # remaining 5_000, so the new credit can only fund room-b.
    conn =
      post_operations(conn, [
        %{
          "operation_id" => "op-apply",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-25",
          "group_id" => "group-81",
          "amount_cents" => 5_000
        }
      ])

    assert %{"results" => [%{"outstanding_deposit_cents" => 5_500}]} = json_response(conn, 200)

    assert %{
             "rooms" => [
               %{"room_id" => "room-a", "cash_paid_cents" => 4_000, "credit_paid_cents" => 5_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 5_000}
             ]
           } = fetch_group!(conn, "group-81")
  end

  defp record_payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => @occurred_on,
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp reduce_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => @occurred_on,
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp charge_back_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => @occurred_on,
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp ledger(conn) do
    assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger"), 200)
    data
  end
end
