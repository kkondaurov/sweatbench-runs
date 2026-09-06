defmodule GroupStayWeb.ApplyHotelCreditTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
  end

  defp credit_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-6001",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-81",
        "amount_cents" => 3000
      },
      overrides
    )
  end

  defp fund_credit(conn, suffix, cash_cents, cancel_on, open_on \\ "2026-10-03") do
    group_id = "group-fund-#{suffix}"

    open_group_fixture(conn, %{
      "operation_id" => "op-open-fund-#{suffix}",
      "group_id" => group_id,
      "occurred_on" => open_on
    })

    pay_group(conn, group_id, cash_cents)
    cancel_group(conn, group_id, cancel_on, %{"refund_method" => "hotel_credit"})
  end

  describe "applying" do
    test "redeems credit into the active deposit", %{conn: conn} do
      fund_credit(conn, "a", 5000, "2026-11-26")

      %{"results" => [result]} = submit_batch(conn, [credit_op()])

      assert result == %{
               "operation_id" => "op-6001",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 3000,
               "outstanding_deposit_cents" => 16500,
               "revision" => 2
             }

      data = group_data(conn, "group-81")
      assert data["deposit_paid_cents"] == 3000
      assert data["cash_paid_cents"] == 0
      assert data["credit_paid_cents"] == 3000
      assert data["outstanding_deposit_cents"] == 16500

      assert guest_credit_data(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 2500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-group-fund-a",
                   "remaining_cents" => 2500,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      # Redeeming credit into a deposit does not change the liability.
      assert ledger_data(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }
    end

    test "accepts credit that settles the deposit exactly", %{conn: conn} do
      fund_credit(conn, "a", 19500, "2026-11-26")

      %{"results" => [result]} = submit_batch(conn, [credit_op(%{"amount_cents" => 19500})])

      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 0
      assert group_data(conn, "group-81")["outstanding_deposit_cents"] == 0
    end

    test "combines with cash payments against the same deposit", %{conn: conn} do
      fund_credit(conn, "a", 5000, "2026-11-26")
      submit_batch(conn, [credit_op()])

      pay_group(conn, "group-81", 16500, %{"operation_id" => "op-pay-final"})

      data = group_data(conn, "group-81")
      assert data["deposit_paid_cents"] == 19500
      assert data["cash_paid_cents"] == 16500
      assert data["credit_paid_cents"] == 3000
      assert data["outstanding_deposit_cents"] == 0
      assert ledger_data(conn)["cash_held_cents"] == 16500
    end

    test "consumes lots by earliest expiry", %{conn: conn} do
      fund_credit(conn, "a", 1000, "2026-11-20")
      fund_credit(conn, "b", 1000, "2026-11-26")

      %{"results" => [result]} = submit_batch(conn, [credit_op(%{"amount_cents" => 1500})])
      assert result["status"] == "applied"

      data = guest_credit_data(conn, "guest-22")
      assert data["available_cents"] == 700

      assert data["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-group-fund-b",
                 "remaining_cents" => 700,
                 "expires_on" => "2027-11-26"
               }
             ]
    end

    test "consumes lots by source operation when expiries are equal", %{conn: conn} do
      fund_credit(conn, "b", 1000, "2026-11-26")
      fund_credit(conn, "c", 1000, "2026-11-26")

      %{"results" => [result]} = submit_batch(conn, [credit_op(%{"amount_cents" => 1200})])
      assert result["status"] == "applied"

      data = guest_credit_data(conn, "guest-22")

      assert data["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-group-fund-c",
                 "remaining_cents" => 1000,
                 "expires_on" => "2027-11-26"
               }
             ]
    end

    test "evaluates expiry using the operation's occurred_on", %{conn: conn} do
      fund_credit(conn, "a", 5000, "2026-11-26")

      %{"results" => [on_expiry, after_expiry]} =
        submit_batch(conn, [
          credit_op(%{"operation_id" => "op-6001", "occurred_on" => "2027-11-26"}),
          credit_op(%{"operation_id" => "op-6002", "occurred_on" => "2027-11-27"})
        ])

      assert on_expiry["status"] == "applied"
      assert after_expiry["status"] == "rejected"
      assert after_expiry["code"] == "insufficient_credit"
    end
  end

  describe "rejections" do
    test "rejects when the guest cannot cover the amount", %{conn: conn} do
      fund_credit(conn, "a", 1000, "2026-11-26")

      %{"results" => [result]} = submit_batch(conn, [credit_op(%{"amount_cents" => 1101})])

      assert result == %{
               "operation_id" => "op-6001",
               "status" => "rejected",
               "code" => "insufficient_credit",
               "group_id" => "group-81"
             }

      data = group_data(conn, "group-81")
      assert data["revision"] == 1
      assert data["credit_paid_cents"] == 0
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 1100
    end

    test "rejects a guest with no credit", %{conn: conn} do
      %{"results" => [result]} = submit_batch(conn, [credit_op()])

      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"
    end

    test "rejects expired credit", %{conn: conn} do
      fund_credit(conn, "old", 2000, "2025-01-01", "2024-12-01")

      %{"results" => [result]} =
        submit_batch(conn, [credit_op(%{"amount_cents" => 100, "occurred_on" => "2026-01-02"})])

      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"
    end

    test "rejects credit exceeding the outstanding deposit", %{conn: conn} do
      fund_credit(conn, "a", 19500, "2026-11-26")

      %{"results" => [result]} = submit_batch(conn, [credit_op(%{"amount_cents" => 19501})])

      assert result["status"] == "rejected"
      assert result["code"] == "payment_exceeds_outstanding"
      assert group_data(conn, "group-81")["credit_paid_cents"] == 0
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 21450
    end

    test "rejects amounts that are not usable", %{conn: conn} do
      fund_credit(conn, "a", 19500, "2026-11-26")

      ops =
        for {amount, index} <- Enum.with_index([0, -100, "3000", 10.5, true]) do
          credit_op(%{"operation_id" => "op-#{index}", "amount_cents" => amount})
        end

      %{"results" => results} = submit_batch(conn, ops)

      assert Enum.all?(results, &(&1["status"] == "rejected"))
      assert Enum.all?(results, &(&1["code"] == "invalid_amount"))
    end

    test "rejects credit for a missing group", %{conn: conn} do
      %{"results" => [result]} = submit_batch(conn, [credit_op(%{"group_id" => "group-404"})])

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"
    end

    test "rejects credit for a cancelled group", %{conn: conn} do
      fund_credit(conn, "a", 5000, "2026-11-26")
      cancel_group(conn, "group-81", "2026-11-26")

      %{"results" => [result]} = submit_batch(conn, [credit_op()])

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"
    end

    test "rejects an operation missing its amount as invalid_operation", %{conn: conn} do
      %{"results" => [result]} =
        submit_batch(conn, [Map.delete(credit_op(), "amount_cents")])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
    end

    test "a rejected application leaves the group and ledger unchanged", %{conn: conn} do
      fund_credit(conn, "a", 1000, "2026-11-26")
      submit_batch(conn, [credit_op(%{"amount_cents" => 5000})])

      data = group_data(conn, "group-81")
      assert data["revision"] == 1
      assert data["deposit_paid_cents"] == 0

      assert ledger_data(conn)["credit_liability_cents"] == 1100
    end
  end

  describe "expected_revision" do
    test "applies when the expected revision matches", %{conn: conn} do
      fund_credit(conn, "a", 5000, "2026-11-26")

      %{"results" => [result]} =
        submit_batch(conn, [Map.put(credit_op(), "expected_revision", 1)])

      assert result["status"] == "applied"
      assert result["revision"] == 2
    end

    test "rejects a stale revision before the credit rules", %{conn: conn} do
      %{"results" => [result]} =
        submit_batch(conn, [
          credit_op(%{"amount_cents" => 999_999}) |> Map.put("expected_revision", 4)
        ])

      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 1
      assert group_data(conn, "group-81")["revision"] == 1
    end

    test "an insufficient-credit attempt does not advance the revision", %{conn: conn} do
      fund_credit(conn, "a", 5000, "2026-11-26")

      submit_batch(conn, [credit_op(%{"amount_cents" => 9999})])

      %{"results" => [result]} =
        submit_batch(conn, [
          credit_op(%{"operation_id" => "op-6002", "amount_cents" => 1000})
          |> Map.put("expected_revision", 1)
        ])

      assert result["status"] == "applied"
      assert result["revision"] == 2
    end
  end
end
