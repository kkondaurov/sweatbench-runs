defmodule GroupStayWeb.RecordCashPaymentTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-2001",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  test "applies cash to an active group's outstanding deposit", %{conn: conn} do
    %{"results" => [result]} = submit_batch(conn, [payment_op()])

    assert result == %{
             "operation_id" => "op-2001",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 5000,
             "outstanding_deposit_cents" => 14500,
             "revision" => 2
           }

    data = group_data(conn, "group-81")
    assert data["deposit_paid_cents"] == 5000
    assert data["outstanding_deposit_cents"] == 14500

    assert ledger_data(conn) == %{
             "cash_held_cents" => 5000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  test "accepts a payment that settles the deposit exactly", %{conn: conn} do
    %{"results" => [result]} = submit_batch(conn, [payment_op(%{"amount_cents" => 19500})])

    assert result["status"] == "applied"
    assert result["outstanding_deposit_cents"] == 0
    assert group_data(conn, "group-81")["outstanding_deposit_cents"] == 0
  end

  test "accumulates several payments", %{conn: conn} do
    first = payment_op()
    second = %{payment_op() | "operation_id" => "op-2002", "amount_cents" => 4500}

    %{"results" => [first_result, second_result]} = submit_batch(conn, [first, second])

    assert first_result["outstanding_deposit_cents"] == 14500
    assert second_result["outstanding_deposit_cents"] == 10000
    assert second_result["revision"] == 3
    assert ledger_data(conn)["cash_held_cents"] == 9500
  end

  test "rejects a payment that exceeds the outstanding deposit", %{conn: conn} do
    %{"results" => [result]} = submit_batch(conn, [payment_op(%{"amount_cents" => 19501})])

    assert result["status"] == "rejected"
    assert result["code"] == "payment_exceeds_outstanding"
    assert result["group_id"] == "group-81"

    assert group_data(conn, "group-81")["deposit_paid_cents"] == 0
    assert ledger_data(conn)["cash_held_cents"] == 0
  end

  test "rejects amounts that are not usable as a payment", %{conn: conn} do
    ops =
      for {amount, index} <- Enum.with_index([0, -100, "5000", 10.5, true]) do
        payment_op(%{"operation_id" => "op-#{index}", "amount_cents" => amount})
      end

    %{"results" => results} = submit_batch(conn, ops)

    assert Enum.all?(results, &(&1["status"] == "rejected"))
    assert Enum.all?(results, &(&1["code"] == "invalid_amount"))
  end

  test "rejects a payment missing its amount as invalid_operation", %{conn: conn} do
    %{"results" => [result]} =
      submit_batch(conn, [Map.delete(payment_op(), "amount_cents")])

    assert result["status"] == "rejected"
    assert result["code"] == "invalid_operation"
  end

  test "rejects a payment for a missing group", %{conn: conn} do
    %{"results" => [result]} = submit_batch(conn, [payment_op(%{"group_id" => "group-404"})])

    assert result["status"] == "rejected"
    assert result["code"] == "group_not_found"
  end

  test "rejects a payment for a cancelled group", %{conn: conn} do
    submit_batch(conn, [
      %{
        "operation_id" => "op-3001",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      }
    ])

    %{"results" => [result]} = submit_batch(conn, [payment_op()])

    assert result["status"] == "rejected"
    assert result["code"] == "group_not_active"
  end

  test "a rejected payment leaves the group and ledger unchanged", %{conn: conn} do
    submit_batch(conn, [payment_op(%{"amount_cents" => 0})])

    data = group_data(conn, "group-81")
    assert data["revision"] == 1
    assert data["deposit_paid_cents"] == 0

    assert ledger_data(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  describe "expected_revision" do
    test "applies when the expected revision matches", %{conn: conn} do
      %{"results" => [result]} =
        submit_batch(conn, [Map.put(payment_op(), "expected_revision", 1)])

      assert result["status"] == "applied"
      assert result["revision"] == 2
    end

    test "rejects a stale revision with the documented fields", %{conn: conn} do
      %{"results" => [result]} =
        submit_batch(conn, [Map.put(payment_op(), "expected_revision", 5)])

      assert result == %{
               "operation_id" => "op-2001",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 5,
               "actual_revision" => 1
             }

      assert group_data(conn, "group-81")["revision"] == 1
    end

    test "rejects a stale revision before other domain rules", %{conn: conn} do
      operation = payment_op(%{"amount_cents" => 0}) |> Map.put("expected_revision", 9)

      %{"results" => [result]} = submit_batch(conn, [operation])

      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 1
    end

    test "resolves group existence before comparing revisions", %{conn: conn} do
      operation = payment_op(%{"group_id" => "group-404"}) |> Map.put("expected_revision", 1)

      %{"results" => [result]} = submit_batch(conn, [operation])

      assert result["code"] == "group_not_found"
    end

    test "observes revisions created earlier in the same batch", %{conn: conn} do
      first = payment_op(%{"amount_cents" => 1000}) |> Map.put("expected_revision", 1)

      second =
        payment_op(%{"operation_id" => "op-2002", "amount_cents" => 1000})
        |> Map.put("expected_revision", 2)

      stale =
        payment_op(%{"operation_id" => "op-2003", "amount_cents" => 1000})
        |> Map.put("expected_revision", 1)

      %{"results" => [first_result, second_result, stale_result]} =
        submit_batch(conn, [first, second, stale])

      assert first_result["status"] == "applied"
      assert second_result["status"] == "applied"
      assert second_result["revision"] == 3

      assert stale_result["code"] == "stale_revision"
      assert stale_result["expected_revision"] == 1
      assert stale_result["actual_revision"] == 3
    end

    test "omitting expected_revision preserves unconditional behavior", %{conn: conn} do
      submit_batch(conn, [payment_op()])
      %{"results" => [result]} = submit_batch(conn, [payment_op(%{"operation_id" => "op-2002"})])

      assert result["status"] == "applied"
      assert result["revision"] == 3
    end
  end
end
