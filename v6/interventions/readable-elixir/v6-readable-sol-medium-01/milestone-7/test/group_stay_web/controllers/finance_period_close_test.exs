defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  describe "closing periods" do
    test "validates the cutoff and durably replays successful and rejected closes", %{conn: conn} do
      conn = submit(conn, [close("before-start", "2027-01-01")])
      assert result(conn, 0)["code"] == "invalid_period"

      conn = submit(conn, [start("start", "2027-01-02")])
      assert result(conn, 0)["status"] == "applied"

      conn =
        submit(conn, [
          close("missing", nil),
          close("too-early", "2027-01-01"),
          close("close", "2027-01-03"),
          close("same-cutoff", "2027-01-03"),
          close("earlier-cutoff", "2027-01-02"),
          close("close", "2027-01-03")
        ])

      assert %{"results" => [missing, too_early, closed, same, earlier, replay]} =
               json_response(conn, 200)

      assert missing["code"] == "invalid_period"
      assert too_early["code"] == "invalid_period"

      assert closed == %{
               "operation_id" => "close",
               "status" => "applied",
               "period_end_on" => "2027-01-03"
             }

      assert same["code"] == "invalid_period"
      assert earlier["code"] == "invalid_period"
      assert replay == closed

      conn = submit(conn, [Map.put(close("close", "2027-01-03"), "extra", true)])
      assert result(conn, 0)["code"] == "operation_id_conflict"
    end

    test "publishes snapshots and applies same-batch posting order", %{conn: conn} do
      conn =
        submit(conn, [
          start("start", "2027-02-01"),
          open("group", "2027-02-01"),
          cash("before-close", "group", 1_000, "2027-01-01"),
          close("close-3", "2027-02-03"),
          reduce("after-close", "before-close", 200, "2027-01-02")
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      closed = report(conn, "2027-02-01")
      assert closed["status"] == "closed"
      assert closed["cash"] == [cash_entry("alpha", 0, %{"received_cents" => 1_000}, 1_000)]
      assert closed["late_adjustments"] == empty_late_adjustments()

      open = report(conn, "2027-02-04")
      assert open["status"] == "open"
      assert open["cash"] == [cash_entry("alpha", 1_000, %{}, 800)]

      assert open["late_adjustments"] == %{
               "cash" => [late_cash_entry("alpha", %{"reduced_cents" => 200})],
               "credit" => credit_movements()
             }

      conn = submit(conn, [close("close-4", "2027-02-04")])
      assert result(conn, 0)["status"] == "applied"
      published = report(conn, "2027-02-04")
      assert published["status"] == "closed"

      conn = submit(conn, [cash("next-period", "group", 100, "2027-02-04")])
      assert result(conn, 0)["status"] == "applied"
      assert report(conn, "2027-02-04") == published

      next_day = report(conn, "2027-02-05")
      assert next_day["cash"] == [cash_entry("alpha", 800, %{}, 900)]

      assert next_day["late_adjustments"]["cash"] == [
               late_cash_entry("alpha", %{"received_cents" => 100})
             ]
    end

    test "does not label an operation already dated in the open period as late", %{conn: conn} do
      conn =
        submit(conn, [
          start("start", "2027-03-01"),
          open("group", "2027-03-01"),
          close("close", "2027-03-02"),
          cash("on-open-day", "group", 500, "2027-03-03")
        ])

      report = report(conn, "2027-03-03")
      assert report["cash"] == [cash_entry("alpha", 0, %{"received_cents" => 500}, 500)]
      assert report["late_adjustments"] == empty_late_adjustments()
    end

    test "preserves signed zero-net late adjustments and reports late credit separately", %{
      conn: conn
    } do
      conn =
        submit(conn, [
          start("start", "2027-04-01"),
          open("refunded", "2027-04-01"),
          cash("refunded-pay", "refunded", 1_000, "2027-04-01"),
          cancel("refund", "refunded", "2027-04-02"),
          open("credit", "2027-04-01"),
          cash("credit-pay", "credit", 1_000, "2027-04-01"),
          close("close", "2027-04-02"),
          chargeback("late-chargeback", "refunded-pay", "2027-04-01"),
          cancel_to_credit("late-credit", "credit", "2027-04-01")
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      report = report(conn, "2027-04-03")

      assert report["late_adjustments"]["cash"] == [
               late_cash_entry("alpha", %{
                 "refunded_cents" => -1_000,
                 "converted_to_credit_cents" => 1_000,
                 "charged_back_cents" => 1_000
               })
             ]

      assert report["late_adjustments"]["credit"] ==
               credit_movements(%{"issued_cents" => 1_100})

      assert report["credit"]["movements"] == credit_movements()
      assert report["credit"]["closing_liability_cents"] == 1_100
    end
  end

  defp submit(conn, operations),
    do: post(recycle(conn), ~p"/api/v1/partner-batches", %{operations: operations})

  defp result(conn, index), do: json_response(conn, 200)["results"] |> Enum.at(index)

  defp report(conn, date) do
    conn
    |> recycle()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp start(id, date),
    do: %{"operation_id" => id, "type" => "start_finance_reporting", "starts_on" => date}

  defp close(id, nil),
    do: %{"operation_id" => id, "type" => "close_finance_period"}

  defp close(id, date),
    do: %{"operation_id" => id, "type" => "close_finance_period", "period_end_on" => date}

  defp open(id, occurred_on) do
    %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "occurred_on" => occurred_on,
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => "alpha",
      "arrival_on" => "2028-06-01",
      "departure_on" => "2028-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
    }
  end

  defp cash(id, group, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group,
      "amount_cents" => amount
    }
  end

  defp reduce(id, payment, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment,
      "amount_cents" => amount
    }
  end

  defp chargeback(id, payment, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment
    }
  end

  defp cancel(id, group, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group
    }
  end

  defp cancel_to_credit(id, group, occurred_on),
    do: Map.put(cancel(id, group, occurred_on), "refund_method", "hotel_credit")

  defp cash_entry(property_id, opening, overrides, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => cash_movements(overrides),
      "closing_held_cents" => closing
    }
  end

  defp late_cash_entry(property_id, overrides),
    do: %{"property_id" => property_id, "movements" => cash_movements(overrides)}

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

  defp credit_movements(overrides \\ %{}) do
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

  defp empty_late_adjustments,
    do: %{"cash" => [], "credit" => credit_movements()}
end
