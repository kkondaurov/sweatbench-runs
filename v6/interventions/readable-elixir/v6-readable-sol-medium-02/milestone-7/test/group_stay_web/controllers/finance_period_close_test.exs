defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  describe "closing finance periods" do
    test "validates increasing cutoffs and preserves durable operation semantics", %{conn: conn} do
      close = close_period("close", "2026-10-06")

      assert %{"results" => [%{"code" => "invalid_period", "status" => "rejected"}]} =
               submit(conn, [close_period("before-start", "2026-10-06")])

      assert %{"results" => [_, applied]} =
               submit(build_conn(), [start_reporting(), close])

      assert applied == %{
               "operation_id" => "close",
               "status" => "applied",
               "period_end_on" => "2026-10-06"
             }

      assert %{"results" => [^applied]} = submit(build_conn(), [close])

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
               submit(build_conn(), [%{close | "period_end_on" => "2026-10-07"}])

      for period_end_on <- ["bad", "2026-10-04", "2026-10-06"] do
        assert %{"results" => [%{"code" => "invalid_period", "status" => "rejected"}]} =
                 submit(build_conn(), [close_period("close-#{period_end_on}", period_end_on)])
      end

      assert %{"results" => [%{"status" => "applied"}]} =
               submit(build_conn(), [close_period("later", "2026-10-07")])

      assert daily_report("2026-10-07")["status"] == "closed"
      assert daily_report("2026-10-08")["status"] == "open"
    end

    test "batch order fixes posting dates and closed reports remain unchanged", %{conn: conn} do
      assert %{"results" => results} =
               submit(conn, [
                 start_reporting(),
                 open_group(),
                 payment("before-close", 500, "2026-10-01"),
                 close_period("close", "2026-10-05"),
                 payment("after-close", 300, "2026-10-01")
               ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      closed = daily_report("2026-10-05")

      assert closed == %{
               "date" => "2026-10-05",
               "status" => "closed",
               "cash" => [cash_entry(0, %{"received_cents" => 500}, 500)],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" => empty_late_adjustments()
             }

      first_open = daily_report("2026-10-06")

      assert first_open["cash"] == [cash_entry(500, %{}, 800)]

      assert first_open["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "hotel-a",
                   "movements" => cash_movements(%{"received_cents" => 300})
                 }
               ],
               "credit" => credit_movements(%{})
             }

      assert %{"results" => [%{"status" => "applied"}]} =
               submit(build_conn(), [close_period("close-again", "2026-10-06")])

      assert daily_report("2026-10-05") == closed

      assert %{"results" => [%{"status" => "applied"}]} =
               submit(build_conn(), [payment("later-correction", 200, "2026-10-05")])

      assert daily_report("2026-10-05") == closed
      assert daily_report("2026-10-06") == %{first_open | "status" => "closed"}

      second_open = daily_report("2026-10-07")
      assert second_open["cash"] == [cash_entry(800, %{}, 1_000)]
      assert hd(second_open["late_adjustments"]["cash"])["movements"]["received_cents"] == 200
    end

    test "retains signed late classifications even when their balance effect nets to zero", %{
      conn: conn
    } do
      assert %{"results" => results} =
               submit(conn, [
                 start_reporting(),
                 open_group(),
                 payment("payment", 1_000, "2026-10-05"),
                 cancel_group(),
                 close_period("close", "2026-10-05"),
                 chargeback("chargeback", "payment", "2026-10-05")
               ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      report = daily_report("2026-10-06")
      assert report["cash"] == []

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "hotel-a",
                 "movements" =>
                   cash_movements(%{"refunded_cents" => -1_000, "charged_back_cents" => 1_000})
               }
             ]
    end

    test "separates late credit movements while including them in closing liability", %{
      conn: conn
    } do
      assert %{"results" => results} =
               submit(conn, [
                 start_reporting(),
                 open_group(),
                 payment("payment", 1_000, "2026-10-05"),
                 close_period("close", "2026-10-05"),
                 %{cancel_group() | "refund_method" => "hotel_credit"}
               ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      report = daily_report("2026-10-06")

      assert report["credit"] == credit_report(0, %{}, 1_100)
      assert report["late_adjustments"]["credit"] == credit_movements(%{"issued_cents" => 1_100})

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "hotel-a",
                 "movements" => cash_movements(%{"converted_to_credit_cents" => 1_000})
               }
             ]
    end
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp daily_report(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp start_reporting do
    %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "occurred_on" => "2026-10-05",
      "starts_on" => "2026-10-05"
    }
  end

  defp close_period(id, period_end_on) do
    %{
      "operation_id" => id,
      "type" => "close_finance_period",
      "occurred_on" => "2026-10-05",
      "period_end_on" => period_end_on
    }
  end

  defp open_group do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel-a",
      "arrival_on" => "2027-03-10",
      "departure_on" => "2027-03-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
    }
  end

  defp payment(id, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => "group",
      "amount_cents" => amount
    }
  end

  defp cancel_group do
    %{
      "operation_id" => "cancel",
      "type" => "cancel_group",
      "occurred_on" => "2026-10-05",
      "group_id" => "group",
      "refund_method" => "cash"
    }
  end

  defp chargeback(id, payment_id, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id
    }
  end

  defp cash_entry(opening, movements, closing) do
    %{
      "property_id" => "hotel-a",
      "opening_held_cents" => opening,
      "movements" => cash_movements(movements),
      "closing_held_cents" => closing
    }
  end

  defp cash_movements(overrides) do
    Map.merge(
      %{
        "received_cents" => 0,
        "transferred_in_cents" => 0,
        "transferred_out_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      overrides
    )
  end

  defp credit_report(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => credit_movements(movements),
      "closing_liability_cents" => closing
    }
  end

  defp empty_late_adjustments do
    %{"cash" => [], "credit" => credit_movements(%{})}
  end

  defp credit_movements(overrides) do
    Map.merge(
      %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      },
      overrides
    )
  end
end
