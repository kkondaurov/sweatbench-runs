defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.Operations

  defp post_operations(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp ledger(conn), do: json_response(get(conn, ~p"/api/v1/ledger"), 200)

  test "starts at zero" do
    conn = build_conn()

    assert ledger(conn) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "tracks cash applied to active reservations" do
    conn = build_conn()

    post_operations(conn, [open(), payment(%{"amount_cents" => 4_000})])

    assert ledger(conn)["data"]["cash_held_cents"] == 4_000
    assert ledger(conn)["data"]["cash_refunded_cents"] == 0
    assert ledger(conn)["data"]["cash_retained_cents"] == 0
    assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 0
    assert ledger(conn)["data"]["credit_liability_cents"] == 0
  end

  test "moves held cash to refunded when a flexible stay is cancelled early" do
    conn = build_conn()

    post_operations(conn, [open(), payment(%{"amount_cents" => 4_000}), cancel()])

    assert ledger(conn) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 4_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "moves held cash to retained for non-refundable cancellations" do
    conn = build_conn()

    late_cancel = cancel(%{"occurred_on" => "2026-12-05"})

    post_operations(conn, [open(), payment(%{"amount_cents" => 4_000}), late_cancel])

    assert ledger(conn) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 4_000,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "sums cash across multiple groups" do
    conn = build_conn()

    other =
      open(%{
        "operation_id" => "op-open-2",
        "group_id" => "group-82",
        "guest_id" => "guest-23"
      })

    other_payment =
      payment(%{"operation_id" => "op-pay-2", "group_id" => "group-82", "amount_cents" => 2_000})

    post_operations(conn, [open(), payment(%{"amount_cents" => 1_000}), other, other_payment])

    assert ledger(conn)["data"]["cash_held_cents"] == 3_000
  end

  test "never counts unpaid deposit requirements as cash" do
    conn = build_conn()

    post_operations(conn, [open()])

    assert ledger(conn)["data"]["cash_held_cents"] == 0
  end
end
