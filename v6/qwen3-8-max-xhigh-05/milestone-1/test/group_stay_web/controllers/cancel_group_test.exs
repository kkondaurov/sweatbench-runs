defmodule GroupStayWeb.CancelGroupTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
  end

  defp cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-4001",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp pay(conn, amount_cents) do
    %{"results" => [result]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-81",
          "amount_cents" => amount_cents
        }
      ])

    result
  end

  test "refunds a flexible group cancelled at least 14 days before arrival", %{conn: conn} do
    pay(conn, 5000)

    # Arrival is 2026-12-10; cancellation on 2026-11-26 is exactly 14 days out.
    %{"results" => [result]} = submit_batch(conn, [cancel_op()])

    assert result == %{
             "operation_id" => "op-4001",
             "status" => "applied",
             "group_id" => "group-81",
             "refunded_cents" => 5000,
             "retained_cents" => 0,
             "revision" => 3
           }

    assert ledger_data(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 5000,
             "cash_retained_cents" => 0
           }

    data = group_data(conn, "group-81")
    assert data["status"] == "cancelled"
    assert data["outstanding_deposit_cents"] == 0
  end

  test "retains cash for a flexible group cancelled inside the refund window", %{conn: conn} do
    pay(conn, 5000)

    # 2026-11-27 is only 13 days before arrival.
    %{"results" => [result]} =
      submit_batch(conn, [cancel_op(%{"occurred_on" => "2026-11-27"})])

    assert result["status"] == "applied"
    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 5000

    assert ledger_data(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 5000
           }
  end

  test "retains cash for a flexible group cancelled after arrival", %{conn: conn} do
    pay(conn, 5000)

    %{"results" => [result]} =
      submit_batch(conn, [cancel_op(%{"occurred_on" => "2026-12-11"})])

    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 5000
  end

  test "advance purchase cancellations are never refundable", %{conn: conn} do
    open_group_fixture(conn, %{
      "operation_id" => "op-1002",
      "group_id" => "group-90",
      "rate_plan" => "advance_purchase"
    })

    %{"results" => [_]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-pay-90",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-90",
          "amount_cents" => 20000
        }
      ])

    %{"results" => [result]} =
      submit_batch(conn, [cancel_op(%{"group_id" => "group-90"})])

    assert result["status"] == "applied"
    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 20000

    assert ledger_data(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 20000
           }
  end

  test "unpaid deposit is simply no longer due", %{conn: conn} do
    %{"results" => [result]} = submit_batch(conn, [cancel_op()])

    assert result["status"] == "applied"
    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 0

    data = group_data(conn, "group-81")
    assert data["status"] == "cancelled"
    assert data["outstanding_deposit_cents"] == 0

    assert ledger_data(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "later operations on a cancelled group are rejected", %{conn: conn} do
    submit_batch(conn, [cancel_op()])

    payment = %{
      "operation_id" => "op-5001",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-11-27",
      "group_id" => "group-81",
      "amount_cents" => 100
    }

    reschedule = %{
      "operation_id" => "op-5002",
      "type" => "reschedule_group",
      "occurred_on" => "2026-11-27",
      "group_id" => "group-81",
      "new_arrival_on" => "2026-12-20"
    }

    cancel_again = %{cancel_op() | "operation_id" => "op-5003"}

    %{"results" => results} = submit_batch(conn, [payment, reschedule, cancel_again])

    assert Enum.all?(results, &(&1["status"] == "rejected"))
    assert Enum.all?(results, &(&1["code"] == "group_not_active"))

    assert group_data(conn, "group-81")["revision"] == 2
  end

  test "rejects cancelling a missing group", %{conn: conn} do
    %{"results" => [result]} = submit_batch(conn, [cancel_op(%{"group_id" => "group-404"})])

    assert result["status"] == "rejected"
    assert result["code"] == "group_not_found"
  end

  test "rejects a stale cancellation before other rules", %{conn: conn} do
    operation = Map.put(cancel_op(), "expected_revision", 2)

    %{"results" => [result]} = submit_batch(conn, [operation])

    assert result["code"] == "stale_revision"
    assert result["actual_revision"] == 1
    assert group_data(conn, "group-81")["status"] == "active"
  end
end
