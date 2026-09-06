defmodule GroupStayWeb.CancelGroupCreditTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
  end

  describe "hotel credit on refundable cancellation" do
    test "converts the cash into a credit lot worth 110%", %{conn: conn} do
      pay_group(conn, "group-81", 5000)

      result =
        cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})

      assert result == %{
               "operation_id" => "op-cancel-group-81",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 5500,
               "revision" => 3
             }

      assert ledger_data(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0
             }

      assert guest_credit_data(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-group-81",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      assert group_data(conn, "group-81")["status"] == "cancelled"
    end

    test "applies the standard rounding rule to the 10% bonus", %{conn: conn} do
      pay_group(conn, "group-81", 1005)

      result =
        cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})

      # 10% of 1005 is 100.5, which rounds up to 101.
      assert result["credit_issued_cents"] == 1106

      assert guest_credit_data(conn, "guest-22")["available_cents"] == 1106
      assert ledger_data(conn)["cash_converted_to_credit_cents"] == 1005
    end

    test "omitting refund_method still refunds cash", %{conn: conn} do
      pay_group(conn, "group-81", 5000)
      result = cancel_group(conn, "group-81", "2026-11-26")

      assert result["refunded_cents"] == 5000
      assert result["credit_issued_cents"] == 0
      assert guest_credit_data(conn, "guest-22")["lots"] == []
    end

    test "an explicit cash refund_method behaves like the default", %{conn: conn} do
      pay_group(conn, "group-81", 5000)
      result = cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "cash"})

      assert result["refunded_cents"] == 5000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert ledger_data(conn)["cash_converted_to_credit_cents"] == 0
    end

    test "issues no lot when no cash was paid", %{conn: conn} do
      result =
        cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert guest_credit_data(conn, "guest-22")["available_cents"] == 0
      assert ledger_data(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger_data(conn)["credit_liability_cents"] == 0
    end
  end

  describe "hotel credit cannot bypass a non-refundable policy" do
    test "rejects hotel credit inside the refund window", %{conn: conn} do
      pay_group(conn, "group-81", 5000)

      result =
        cancel_group(conn, "group-81", "2026-11-27", %{"refund_method" => "hotel_credit"})

      assert result == %{
               "operation_id" => "op-cancel-group-81",
               "status" => "rejected",
               "code" => "refund_method_not_available",
               "group_id" => "group-81"
             }

      data = group_data(conn, "group-81")
      assert data["status"] == "active"
      assert data["revision"] == 2

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

    test "rejects hotel credit for an advance purchase group", %{conn: conn} do
      open_group_fixture(conn, %{
        "operation_id" => "op-1002",
        "group_id" => "group-90",
        "rate_plan" => "advance_purchase"
      })

      pay_group(conn, "group-90", 20000)

      result =
        cancel_group(conn, "group-90", "2026-11-26", %{"refund_method" => "hotel_credit"})

      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"
      assert group_data(conn, "group-90")["status"] == "active"
    end

    test "a rejected refund method does not advance the revision", %{conn: conn} do
      cancel_group(conn, "group-81", "2026-11-27", %{"refund_method" => "hotel_credit"})

      result =
        cancel_group(conn, "group-81", "2026-11-26", %{
          "operation_id" => "op-cancel-group-81-again",
          "expected_revision" => 1
        })

      assert result["status"] == "applied"
      assert result["revision"] == 2
    end

    test "a stale revision is rejected before the refund method", %{conn: conn} do
      result =
        cancel_group(conn, "group-81", "2026-11-27", %{
          "refund_method" => "hotel_credit",
          "expected_revision" => 4
        })

      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 1
    end

    test "cash cancellation still works inside the refund window", %{conn: conn} do
      pay_group(conn, "group-81", 5000)
      result = cancel_group(conn, "group-81", "2026-11-27")

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5000
    end
  end

  describe "refund_method validation" do
    test "rejects unknown refund methods as invalid_operation", %{conn: conn} do
      result =
        cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "voucher"})

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
      assert group_data(conn, "group-81")["status"] == "active"
    end
  end
end
