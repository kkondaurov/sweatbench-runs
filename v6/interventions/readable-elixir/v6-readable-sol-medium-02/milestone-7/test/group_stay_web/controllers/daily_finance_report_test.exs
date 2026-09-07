defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  describe "reporting inception" do
    test "uses the state immediately before the start operation and clamps later postings", %{
      conn: conn
    } do
      assert %{"results" => [_, _, started, paid]} =
               submit(conn, [
                 open_group("group", "hotel-a"),
                 payment("before", "group", 500, "2026-10-10"),
                 start_reporting("start", "2026-10-05"),
                 payment("after", "group", 300, "2026-10-01")
               ])

      assert started == %{
               "operation_id" => "start",
               "starts_on" => "2026-10-05",
               "status" => "applied"
             }

      assert paid["status"] == "applied"

      report = get_json("/api/v1/finance/daily-report?date=2026-10-05")["data"]

      assert report == %{
               "date" => "2026-10-05",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "hotel-a",
                   "opening_held_cents" => 500,
                   "movements" => cash_movements(%{"received_cents" => 300}),
                   "closing_held_cents" => 800
                 }
               ],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" => empty_late_adjustments()
             }
    end

    test "validates start and report dates, availability, uniqueness, and durable replay", %{
      conn: conn
    } do
      assert get_json(conn, "/api/v1/finance/daily-report?date=bad", 422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }

      assert get_json(build_conn(), "/api/v1/finance/daily-report", 422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }

      assert get_json(conn, "/api/v1/finance/daily-report?date=2026-10-05", 404) == %{
               "error" => %{"code" => "report_not_available"}
             }

      invalid = %{start_reporting("invalid", "bad") | "occurred_on" => "2026-10-01"}
      assert %{"results" => [%{"code" => "invalid_reporting_date"}]} = submit(conn, [invalid])

      start = start_reporting("start", "2026-10-05")
      assert %{"results" => [applied]} = submit(build_conn(), [start])
      assert %{"results" => [^applied]} = submit(build_conn(), [start])

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
               submit(build_conn(), [%{start | "starts_on" => "2026-10-06"}])

      assert %{"results" => [%{"code" => "reporting_already_started"}]} =
               submit(build_conn(), [start_reporting("another", "2026-10-05")])

      assert get_json(build_conn(), "/api/v1/finance/daily-report?date=2026-10-04", 404) == %{
               "error" => %{"code" => "report_not_available"}
             }
    end
  end

  describe "cash movements" do
    test "reports receipts, transfers, refunds, reductions, and chargeback reclassification", %{
      conn: conn
    } do
      assert %{"results" => results} =
               submit(conn, [
                 start_reporting("start", "2026-10-05"),
                 open_group("source", "hotel-a"),
                 open_group("destination", "hotel-b"),
                 payment("pay", "source", 1_000, "2026-10-06"),
                 transfer("move", "source", "destination", 400, "2026-10-06"),
                 cancel("refund", "destination", "2026-10-07")
               ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      day_six = get_json("/api/v1/finance/daily-report?date=2026-10-06")["data"]

      assert day_six["cash"] == [
               cash_entry(
                 "hotel-a",
                 0,
                 %{
                   "received_cents" => 1_000,
                   "transferred_out_cents" => 400
                 },
                 600
               ),
               cash_entry("hotel-b", 0, %{"transferred_in_cents" => 400}, 400)
             ]

      day_seven = get_json("/api/v1/finance/daily-report?date=2026-10-07")["data"]

      assert day_seven["cash"] == [
               cash_entry("hotel-a", 600, %{}, 600),
               cash_entry("hotel-b", 400, %{"refunded_cents" => 400}, 0)
             ]

      assert %{"results" => [reduced, charged]} =
               submit(build_conn(), [
                 reduction("reduce", "pay", 200, "2026-10-08"),
                 chargeback("chargeback", "pay", "2026-10-09")
               ])

      assert reduced["status"] == "applied"
      assert charged["status"] == "applied"

      day_nine = get_json("/api/v1/finance/daily-report?date=2026-10-09")["data"]

      assert day_nine["cash"] == [
               cash_entry("hotel-a", 400, %{"charged_back_cents" => 400}, 0),
               cash_entry(
                 "hotel-b",
                 0,
                 %{"refunded_cents" => -400, "charged_back_cents" => 400},
                 0
               )
             ]
    end

    test "rejected operations and retries never add movements", %{conn: conn} do
      pay = payment("pay", "group", 500, "2026-10-06")

      assert %{"results" => [_, _, rejected]} =
               submit(conn, [
                 start_reporting("start", "2026-10-05"),
                 open_group("group", "hotel"),
                 %{pay | "amount_cents" => 5_000}
               ])

      assert rejected["status"] == "rejected"
      assert %{"results" => [%{"code" => "operation_id_conflict"}]} = submit(build_conn(), [pay])

      valid = payment("valid", "group", 500, "2026-10-06")
      assert %{"results" => [applied]} = submit(build_conn(), [valid])
      assert %{"results" => [^applied]} = submit(build_conn(), [valid])

      report = get_json("/api/v1/finance/daily-report?date=2026-10-06")["data"]
      assert hd(report["cash"])["movements"]["received_cents"] == 500
    end
  end

  describe "credit movements" do
    test "reports issuance, consumption, and expiry on a day with no operation", %{conn: conn} do
      assert %{"results" => results} =
               submit(conn, [
                 start_reporting("start", "2026-10-05"),
                 open_group("source", "hotel"),
                 payment("pay", "source", 1_000, "2026-10-06"),
                 cancel("issue", "source", "2026-10-07", "hotel_credit"),
                 open_group("advance", "hotel", "advance_purchase"),
                 apply_credit("use", "advance", 400, "2026-10-08"),
                 cancel("consume", "advance", "2026-10-09")
               ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      issued = get_json("/api/v1/finance/daily-report?date=2026-10-07")["data"]["credit"]
      assert issued == credit_report(0, %{"issued_cents" => 1_100}, 1_100)

      consumed = get_json("/api/v1/finance/daily-report?date=2026-10-09")["data"]["credit"]
      assert consumed == credit_report(1_100, %{"consumed_cents" => 400}, 700)

      expired = get_json("/api/v1/finance/daily-report?date=2027-10-08")["data"]["credit"]
      assert expired == credit_report(700, %{"expired_cents" => 700}, 0)

      assert get_json("/api/v1/finance/daily-report?date=2027-10-08") ==
               get_json("/api/v1/finance/daily-report?date=2027-10-08")
    end

    test "classifies chargeback revocation and later shortfall absorption", %{conn: conn} do
      assert %{"results" => results} =
               submit(conn, [
                 start_reporting("start", "2026-10-05"),
                 open_group("source", "hotel"),
                 payment("pay", "source", 1_000, "2026-10-06"),
                 cancel("issue", "source", "2026-10-07", "hotel_credit"),
                 open_group("destination", "hotel"),
                 apply_credit("use", "destination", 1_100, "2026-10-08"),
                 chargeback("chargeback", "pay", "2026-10-09"),
                 cancel("absorb", "destination", "2026-10-10")
               ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      chargeback =
        get_json("/api/v1/finance/daily-report?date=2026-10-09")["data"]["credit"]

      assert chargeback == credit_report(1_100, %{}, 1_100)

      absorbed = get_json("/api/v1/finance/daily-report?date=2026-10-10")["data"]["credit"]
      assert absorbed == credit_report(1_100, %{"absorbed_cents" => 1_100}, 0)
    end

    test "classifies the available portion of a clawed-back lot as revoked", %{conn: conn} do
      assert %{"results" => results} =
               submit(conn, [
                 start_reporting("start", "2026-10-05"),
                 open_group("source", "hotel"),
                 payment("pay", "source", 1_000, "2026-10-06"),
                 cancel("issue", "source", "2026-10-07", "hotel_credit"),
                 chargeback("chargeback", "pay", "2026-10-08")
               ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      credit = get_json("/api/v1/finance/daily-report?date=2026-10-08")["data"]["credit"]
      assert credit == credit_report(1_100, %{"revoked_cents" => 1_100}, 0)
    end
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp get_json(path), do: get_json(build_conn(), path, 200)

  defp get_json(conn, path, status) do
    conn |> get(path) |> json_response(status)
  end

  defp start_reporting(id, starts_on) do
    %{
      "operation_id" => id,
      "type" => "start_finance_reporting",
      "occurred_on" => "2026-10-05",
      "starts_on" => starts_on
    }
  end

  defp open_group(group_id, property_id, rate_plan \\ "flexible") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => property_id,
      "arrival_on" => "2027-03-10",
      "departure_on" => "2027-03-11",
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
    }
  end

  defp payment(id, group_id, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(id, source, destination, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp cancel(id, group_id, occurred_on, refund_method \\ "cash") do
    %{
      "operation_id" => id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp reduction(id, payment_id, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id,
      "amount_cents" => amount
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

  defp apply_credit(id, group_id, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cash_entry(property_id, opening, movements, closing) do
    %{
      "property_id" => property_id,
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
      "movements" =>
        Map.merge(
          %{
            "issued_cents" => 0,
            "expired_cents" => 0,
            "consumed_cents" => 0,
            "revoked_cents" => 0,
            "absorbed_cents" => 0
          },
          movements
        ),
      "closing_liability_cents" => closing
    }
  end

  defp empty_late_adjustments do
    %{
      "cash" => [],
      "credit" => %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      }
    }
  end
end
