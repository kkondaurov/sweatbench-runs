defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  describe "reporting inception" do
    test "validates dates, snapshots preceding operations, and floors later postings", %{
      conn: conn
    } do
      assert json_response(get(conn, "/api/v1/finance/daily-report"), 422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}

      assert json_response(get(conn, "/api/v1/finance/daily-report?date=not-a-date"), 422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}

      assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-05"), 404) ==
               %{"error" => %{"code" => "report_not_available"}}

      start = start_reporting("start", "2026-10-05")

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{
                   "operation_id" => "start",
                   "status" => "applied",
                   "starts_on" => "2026-10-05"
                 },
                 %{"status" => "applied"}
               ]
             } =
               submit(conn, [
                 open_group("open", "group", "ams-canal", 5_000),
                 cash_payment("opening-cash", "group", 400, "2026-10-10"),
                 start,
                 cash_payment("day-cash", "group", 300, "2026-10-01")
               ])

      assert report(conn, "2026-10-04") == {:error, 404, "report_not_available"}

      assert %{
               "date" => "2026-10-05",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 400,
                   "movements" => %{"received_cents" => 300},
                   "closing_held_cents" => 700
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "closing_liability_cents" => 0
               }
             } = report(conn, "2026-10-05")

      assert %{"results" => [replay]} = submit(conn, [start])

      assert replay == %{
               "operation_id" => "start",
               "status" => "applied",
               "starts_on" => "2026-10-05"
             }

      assert %{"results" => [%{"code" => "reporting_already_started"}]} =
               submit(conn, [start_reporting("another-start", "2026-10-06")])
    end

    test "rejects a missing or invalid start date durably", %{conn: conn} do
      invalid = %{"operation_id" => "bad-start", "type" => "start_finance_reporting"}

      assert %{"results" => [%{"code" => "invalid_reporting_date"} = original]} =
               submit(conn, [invalid])

      assert %{"results" => [^original]} = submit(conn, [invalid])

      assert %{"results" => [%{"code" => "invalid_reporting_date"}]} =
               submit(conn, [start_reporting("bad-date", "2026-02-30")])
    end

    test "includes credit created before the start operation in the opening position", %{
      conn: conn
    } do
      submit(conn, [
        open_group("open", "group", "ams", 5_000),
        cash_payment("payment", "group", 1_000, "2026-10-10"),
        cancel("issue", "group", "2026-10-10", "hotel_credit"),
        start_reporting("start", "2026-10-05")
      ])

      credit = report(conn, "2026-10-05")["credit"]
      assert credit["opening_liability_cents"] == 1_100

      assert credit["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert credit["closing_liability_cents"] == 1_100
    end
  end

  describe "cash movements" do
    test "tracks transfers and reverses settlement classifications at their property", %{
      conn: conn
    } do
      submit(conn, [
        open_group("open-source", "source", "ams", 5_000),
        open_group("open-destination", "destination", "bru", 5_000),
        start_reporting("start", "2026-10-01"),
        cash_payment("payment", "source", 1_000, "2026-10-01"),
        transfer("move", "source", "destination", 400, "2026-10-02"),
        cancel("cancel-destination", "destination", "2026-10-03"),
        chargeback("chargeback", "payment", "2026-10-04")
      ])

      assert [bru, ams] = [
               cash_entry(conn, "2026-10-02", "bru"),
               cash_entry(conn, "2026-10-02", "ams")
             ]

      assert bru["movements"]["transferred_in_cents"] == 400
      assert bru["closing_held_cents"] == 400
      assert ams["movements"]["transferred_out_cents"] == 400
      assert ams["closing_held_cents"] == 600

      refund = cash_entry(conn, "2026-10-03", "bru")
      assert refund["movements"]["refunded_cents"] == 400
      assert refund["closing_held_cents"] == 0

      destination_correction = cash_entry(conn, "2026-10-04", "bru")
      assert destination_correction["movements"]["refunded_cents"] == -400
      assert destination_correction["movements"]["charged_back_cents"] == 400
      assert destination_correction["closing_held_cents"] == 0

      source_correction = cash_entry(conn, "2026-10-04", "ams")
      assert source_correction["opening_held_cents"] == 600
      assert source_correction["movements"]["charged_back_cents"] == 600
      assert source_correction["closing_held_cents"] == 0
    end

    test "shows both sides of a cash transfer within one property", %{conn: conn} do
      submit(conn, [
        open_group("open-source", "source", "ams", 5_000),
        open_group("open-destination", "destination", "ams", 5_000),
        start_reporting("start", "2026-10-01"),
        cash_payment("payment", "source", 1_000, "2026-10-01"),
        transfer("move", "source", "destination", 400, "2026-10-02")
      ])

      cash = cash_entry(conn, "2026-10-02", "ams")
      assert cash["opening_held_cents"] == 1_000
      assert cash["movements"]["transferred_in_cents"] == 400
      assert cash["movements"]["transferred_out_cents"] == 400
      assert cash["closing_held_cents"] == 1_000
    end

    test "records reductions once and ignores rejections and durable retries", %{conn: conn} do
      payment = cash_payment("payment", "group", 500, "2026-10-02")

      submit(conn, [
        open_group("open", "group", "ams", 5_000),
        start_reporting("start", "2026-10-01"),
        payment,
        cash_payment("rejected", "group", 600, "2026-10-02"),
        reduce("reduce", "payment", 200, "2026-10-02")
      ])

      assert %{"results" => [%{"status" => "applied"}]} = submit(conn, [payment])

      cash = cash_entry(conn, "2026-10-02", "ams")
      assert cash["movements"]["received_cents"] == 500
      assert cash["movements"]["reduced_cents"] == 200
      assert cash["closing_held_cents"] == 300
    end
  end

  describe "credit movements" do
    test "reports issue, consumption, automatic expiry, and late changes without mutating reads",
         %{
           conn: conn
         } do
      submit(conn, [
        open_group("open-source", "source", "ams", 5_000),
        start_reporting("start", "2026-10-01"),
        cash_payment("payment", "source", 1_000, "2026-10-01"),
        cancel("issue", "source", "2026-10-02", "hotel_credit"),
        open_advance_group("open-use", "use", "bru", 400),
        hotel_credit("use-credit", "use", 400, "2026-10-03"),
        cancel("consume", "use", "2026-10-04")
      ])

      issue = report(conn, "2026-10-02")["credit"]
      assert issue["movements"]["issued_cents"] == 1_100
      assert issue["closing_liability_cents"] == 1_100

      consumed = report(conn, "2026-10-04")["credit"]
      assert consumed["movements"]["consumed_cents"] == 400
      assert consumed["closing_liability_cents"] == 700

      first_expiry = report(conn, "2027-10-03")["credit"]
      assert first_expiry["movements"]["expired_cents"] == 700
      assert first_expiry["closing_liability_cents"] == 0
      assert report(conn, "2027-10-03")["credit"] == first_expiry

      submit(conn, [
        open_advance_group("open-late-use", "late-use", "cdg", 200, "2027-10-02"),
        hotel_credit("late-use-credit", "late-use", 200, "2027-10-02")
      ])

      revised_expiry = report(conn, "2027-10-03")["credit"]
      assert revised_expiry["opening_liability_cents"] == 700
      assert revised_expiry["movements"]["expired_cents"] == 500
      assert revised_expiry["closing_liability_cents"] == 200
    end

    test "classifies chargeback revocation and later shortfall absorption", %{conn: conn} do
      submit(conn, [
        open_group("open-source", "source", "ams", 5_000),
        start_reporting("start", "2026-10-01"),
        cash_payment("payment", "source", 1_000, "2026-10-01"),
        cancel("issue", "source", "2026-10-02", "hotel_credit"),
        open_group("open-use", "use", "bru", 5_000),
        hotel_credit("use-credit", "use", 500, "2026-10-03"),
        chargeback("chargeback", "payment", "2026-10-04"),
        cancel("restore", "use", "2026-10-05")
      ])

      revoked = report(conn, "2026-10-04")["credit"]
      assert revoked["opening_liability_cents"] == 1_100
      assert revoked["movements"]["revoked_cents"] == 600
      assert revoked["closing_liability_cents"] == 500

      absorbed = report(conn, "2026-10-05")["credit"]
      assert absorbed["opening_liability_cents"] == 500
      assert absorbed["movements"]["absorbed_cents"] == 500
      assert absorbed["closing_liability_cents"] == 0
    end

    test "expires restored credit immediately when its original lot is already expired", %{
      conn: conn
    } do
      submit(conn, [
        open_group("open-source", "source", "ams", 5_000),
        start_reporting("start", "2026-10-01"),
        cash_payment("payment", "source", 1_000, "2026-10-01"),
        cancel("issue", "source", "2026-10-02", "hotel_credit"),
        open_future_group("open-use", "use", "bru", 5_000),
        hotel_credit("use-credit", "use", 400, "2026-10-03"),
        cancel("restore-expired", "use", "2027-10-04")
      ])

      expiry = report(conn, "2027-10-03")["credit"]
      assert expiry["movements"]["expired_cents"] == 700
      assert expiry["closing_liability_cents"] == 400

      restoration = report(conn, "2027-10-04")["credit"]
      assert restoration["opening_liability_cents"] == 400
      assert restoration["movements"]["expired_cents"] == 400
      assert restoration["closing_liability_cents"] == 0
    end
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp report(conn, date) do
    case get(conn, "/api/v1/finance/daily-report?date=#{date}") do
      %{status: 200} = conn -> json_response(conn, 200)["data"]
      %{status: status} = conn -> {:error, status, json_response(conn, status)["error"]["code"]}
    end
  end

  defp cash_entry(conn, date, property_id) do
    report(conn, date)["cash"]
    |> Enum.find(&(&1["property_id"] == property_id))
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp open_group(operation_id, group_id, property_id, nightly_rate) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => property_id,
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-21",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => nightly_rate}]
    }
  end

  defp open_advance_group(operation_id, group_id, property_id, due, occurred_on \\ "2026-09-01") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => property_id,
      "arrival_on" => "2028-12-20",
      "departure_on" => "2028-12-21",
      "rate_plan" => "advance_purchase",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => due}]
    }
  end

  defp open_future_group(operation_id, group_id, property_id, nightly_rate) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => property_id,
      "arrival_on" => "2028-12-20",
      "departure_on" => "2028-12-21",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => nightly_rate}]
    }
  end

  defp cash_payment(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp hotel_credit(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(operation_id, source, destination, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp cancel(operation_id, group_id, occurred_on, refund_method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp chargeback(operation_id, payment_operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  defp reduce(operation_id, payment_operation_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount
    }
  end
end
