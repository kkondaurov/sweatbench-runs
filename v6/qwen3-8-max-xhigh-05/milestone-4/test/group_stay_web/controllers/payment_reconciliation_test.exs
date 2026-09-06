defmodule GroupStayWeb.PaymentReconciliationTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
  end

  defp payment_data(conn, payment_operation_id) do
    conn
    |> Phoenix.ConnTest.dispatch(
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/payments/#{payment_operation_id}"
    )
    |> Phoenix.ConnTest.json_response(200)
    |> Map.fetch!("data")
  end

  defp pay(conn, amount_cents, overrides \\ %{}) do
    pay_group(
      conn,
      "group-81",
      amount_cents,
      Map.merge(%{"operation_id" => "op-pay"}, overrides)
    )
  end

  defp reduce(conn, amount_cents, overrides \\ %{}) do
    operation =
      Map.merge(
        %{
          "operation_id" => "op-reduce",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-10",
          "payment_operation_id" => "op-pay",
          "amount_cents" => amount_cents
        },
        overrides
      )

    %{"results" => [result]} = submit_batch(conn, [operation])
    result
  end

  defp charge_back(conn, overrides \\ %{}) do
    operation =
      Map.merge(
        %{
          "operation_id" => "op-charge-back",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-11",
          "payment_operation_id" => "op-pay"
        },
        overrides
      )

    %{"results" => [result]} = submit_batch(conn, [operation])
    result
  end

  test "reports the current disposition of a recorded payment", %{conn: conn} do
    pay(conn, 5000)

    assert payment_data(conn, "op-pay") == %{
             "payment_operation_id" => "op-pay",
             "original_group_id" => "group-81",
             "recorded_cents" => 5000,
             "held_cents" => 5000,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }
  end

  test "the disposition fields sum exactly to recorded_cents through a full lifecycle", %{
    conn: conn
  } do
    pay(conn, 5000)
    reduce(conn, 1000)
    cancel_group(conn, "group-81", "2026-11-26")
    charge_back(conn)

    statement = payment_data(conn, "op-pay")

    assert statement == %{
             "payment_operation_id" => "op-pay",
             "original_group_id" => "group-81",
             "recorded_cents" => 5000,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 1000,
             "charged_back_cents" => 4000
           }

    dispositions =
      Map.take(statement, [
        "held_cents",
        "refunded_cents",
        "retained_cents",
        "converted_to_credit_cents",
        "reduced_cents",
        "charged_back_cents"
      ])

    assert Enum.sum(Map.values(dispositions)) == statement["recorded_cents"]
  end

  test "reflects refunded, retained, and converted settlements", %{conn: conn} do
    open_group_fixture(conn, %{
      "operation_id" => "op-open-82",
      "group_id" => "group-82",
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-23"
    })

    open_group_fixture(conn, %{
      "operation_id" => "op-open-83",
      "group_id" => "group-83",
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-23"
    })

    pay_group(conn, "group-82", 2000, %{"operation_id" => "op-pay-refunded"})
    pay_group(conn, "group-83", 3000, %{"operation_id" => "op-pay-retained"})
    pay(conn, 4000)

    cancel_group(conn, "group-82", "2026-11-26")
    cancel_group(conn, "group-83", "2026-12-09")
    cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})

    assert payment_data(conn, "op-pay-refunded")["refunded_cents"] == 2000
    assert payment_data(conn, "op-pay-retained")["retained_cents"] == 3000
    assert payment_data(conn, "op-pay")["converted_to_credit_cents"] == 4000
  end

  test "agrees with the group, room, and ledger views", %{conn: conn} do
    pay(conn, 10000)
    reduce(conn, 2500)

    statement = payment_data(conn, "op-pay")
    data = group_data(conn, "group-81")
    ledger = ledger_data(conn)

    assert statement["held_cents"] == data["cash_paid_cents"]
    assert statement["held_cents"] == ledger["cash_held_cents"]
    assert statement["reduced_cents"] == ledger["cash_reduced_cents"]

    rooms_held =
      data["rooms"]
      |> Enum.map(& &1["cash_paid_cents"])
      |> Enum.sum()

    assert statement["held_cents"] == rooms_held
  end

  test "reading a statement never changes state", %{conn: conn} do
    pay(conn, 5000)
    reduce(conn, 1000)

    before_group = group_data(conn, "group-81")
    before_ledger = ledger_data(conn)
    first = payment_data(conn, "op-pay")
    second = payment_data(conn, "op-pay")

    assert first == second
    assert group_data(conn, "group-81") == before_group
    assert ledger_data(conn) == before_ledger
  end

  test "returns operation_not_found when no durable record exists", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/payments/op-missing")

    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end

  test "returns payment_not_reconcilable for a record that is not an applied cash payment", %{
    conn: conn
  } do
    # An operation that is not a payment at all.
    conn = get(conn, ~p"/api/v1/payments/op-1001")
    assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}

    # A rejected payment.
    pay(conn, 999_999)
    conn = get(conn, ~p"/api/v1/payments/op-pay")
    assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
  end

  test "reports every monetary field even when zero", %{conn: conn} do
    pay(conn, 100)

    data = payment_data(conn, "op-pay")

    for field <- [
          "recorded_cents",
          "held_cents",
          "refunded_cents",
          "retained_cents",
          "converted_to_credit_cents",
          "reduced_cents",
          "charged_back_cents"
        ] do
      assert is_integer(data[field])
    end

    assert data["refunded_cents"] == 0
    assert data["charged_back_cents"] == 0
  end
end
