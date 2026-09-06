defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  defp json_header(conn) do
    put_req_header(conn, "content-type", "application/json")
  end

  defp submit_batch(conn, operations) do
    conn
    |> json_header()
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp start_reporting(operation_id, starts_on, occurred_on \\ "2026-10-01") do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "occurred_on" => occurred_on,
      "starts_on" => starts_on
    }
  end

  defp open(group_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "#{group_id}-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-02",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "prop-1",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "r1", "nightly_rate_cents" => 10_000},
          %{"room_id" => "r2", "nightly_rate_cents" => 10_000}
        ]
      },
      extra
    )
  end

  defp pay(group_id, amount_cents, operation_id, occurred_on \\ "2026-10-03") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel(group_id, occurred_on, operation_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      extra
    )
  end

  defp apply_credit(group_id, amount_cents, occurred_on, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer(source, destination, amount_cents, operation_id, occurred_on \\ "2026-10-05") do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount_cents
    }
  end

  defp reduce(payment_operation_id, amount_cents, operation_id, occurred_on \\ "2026-10-06") do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back(payment_operation_id, operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
  end

  defp report_ok(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
  end

  defp ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
  end

  defp credit_movements(conn, date, kind) do
    %{"data" => %{"credit" => credit}} = report_ok(conn, date)
    credit["movements"][kind]
  end

  defp cash_entry(conn, date, property_id) do
    %{"data" => %{"cash" => cash}} = report_ok(conn, date)
    Enum.find(cash, &(&1["property_id"] == property_id))
  end

  describe "start_finance_reporting" do
    test "applies once and returns the stored result on retry", %{conn: conn} do
      op = start_reporting("start-1", "2026-10-01")

      assert %{"results" => [applied]} = submit_batch(conn, [op])

      assert applied == %{
               "operation_id" => "start-1",
               "status" => "applied",
               "starts_on" => "2026-10-01"
             }

      # A different start operation is rejected.
      assert %{"results" => [%{"code" => "reporting_already_started"}]} =
               submit_batch(conn, [start_reporting("start-2", "2026-10-02")])

      # The retry replays the stored result.
      assert %{"results" => [again]} = submit_batch(conn, [op])
      assert again == applied

      # The durable record is readable.
      assert %{"data" => stored} =
               conn
               |> get("/api/v1/operations/start-1")
               |> json_response(200)

      assert stored == applied
    end

    test "rejects a missing or invalid starts_on as invalid_reporting_date", %{conn: conn} do
      missing = %{
        "operation_id" => "start-x",
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-10-01"
      }

      invalid = start_reporting("start-y", "2026-13-99")
      bad_shape = start_reporting("start-z", "2026-10-01") |> Map.put("starts_on", 12)

      for op <- [missing, invalid, bad_shape] do
        assert %{"results" => [%{"code" => "invalid_reporting_date"}]} =
                 submit_batch(conn, [op])
      end

      # Reporting has not started through any of those.
      assert %{"results" => [applied]} =
               submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      assert applied["status"] == "applied"
    end

    test "operations before the start contribute to the opening position", %{conn: conn} do
      # The payment precedes the start inside the same batch, so it is already
      # part of the financial state when reporting begins.
      assert %{"results" => [_opened, _paid, %{"status" => "applied"}]} =
               submit_batch(conn, [
                 open("g-1"),
                 pay("g-1", 3_000, "p-1"),
                 start_reporting("start-1", "2026-10-01")
               ])

      assert cash_entry(conn, "2026-10-01", "prop-1") == %{
               "property_id" => "prop-1",
               "opening_held_cents" => 3_000,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 3_000
             }
    end

    test "posting dates follow the later of occurred_on and starts_on", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-10")])

      assert %{"results" => [_opened, %{"status" => "applied"}]} =
               submit_batch(conn, [
                 open("g-1"),
                 pay("g-1", 2_000, "p-1", "2026-09-15")
               ])

      # Before starts_on there is no report.
      assert report(conn, "2026-10-09") |> json_response(404) == %{
               "error" => %{"code" => "report_not_available"}
             }

      # The late payment posts on starts_on.
      entry = cash_entry(conn, "2026-10-10", "prop-1")
      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["received_cents"] == 2_000
      assert entry["closing_held_cents"] == 2_000
    end
  end

  describe "reading one day" do
    test "rejects missing or invalid dates and unavailable reports", %{conn: conn} do
      assert conn
             |> get("/api/v1/finance/daily-report")
             |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      assert conn
             |> get("/api/v1/finance/daily-report?date=not-a-date")
             |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      # Nothing has started yet.
      assert conn
             |> get("/api/v1/finance/daily-report?date=2026-10-01")
             |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

      submit_batch(conn, [start_reporting("start-1", "2026-10-10")])

      assert conn
             |> get("/api/v1/finance/daily-report?date=2026-10-09")
             |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
    end

    test "reading a report never changes domain state", %{conn: conn} do
      submit_batch(conn, [
        start_reporting("start-1", "2026-10-01"),
        open("g-1"),
        pay("g-1", 4_000, "p-1")
      ])

      before_revision =
        conn
        |> get("/api/v1/groups/g-1")
        |> json_response(200)
        |> then(& &1["data"]["revision"])

      assert report_ok(conn, "2026-10-03") == report_ok(conn, "2026-10-03")
      assert report_ok(conn, "2026-10-04") != nil
      assert report_ok(conn, "2026-10-03") != nil

      after_revision =
        conn
        |> get("/api/v1/groups/g-1")
        |> json_response(200)
        |> then(& &1["data"]["revision"])

      assert after_revision == before_revision

      assert %{"data" => %{"cash_held_cents" => 4_000}} = ledger(conn)
    end
  end

  describe "cash movements" do
    test "reports refunds, retention and chargebacks per property", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      # A refundable cancellation refunds the held cash.
      submit_batch(conn, [
        open("g-1"),
        pay("g-1", 6_000, "p-1"),
        cancel("g-1", "2026-11-20", "c-1")
      ])

      entry = cash_entry(conn, "2026-11-20", "prop-1")
      assert entry["movements"]["refunded_cents"] == 6_000
      assert entry["closing_held_cents"] == 0

      # A non-refundable cancellation retains it. The second payment is
      # backdated to October, so on December 1 it is already opening cash.
      submit_batch(conn, [
        open("g-2"),
        pay("g-2", 4_000, "p-2"),
        cancel("g-2", "2026-12-01", "c-2")
      ])

      held_entry = cash_entry(conn, "2026-12-01", "prop-1")
      assert held_entry["movements"]["retained_cents"] == 4_000
      assert held_entry["opening_held_cents"] == 4_000
      assert held_entry["closing_held_cents"] == 0

      # Charging the first payment back reverses the refund where it settled.
      submit_batch(conn, [charge_back("p-1", "cb-1", "2026-12-02")])

      entry = cash_entry(conn, "2026-12-02", "prop-1")
      assert entry["movements"]["refunded_cents"] == -6_000
      assert entry["movements"]["charged_back_cents"] == 6_000
      assert entry["opening_held_cents"] == 0
      assert entry["closing_held_cents"] == 0
    end

    test "reports reductions where the cash was held", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      submit_batch(conn, [
        open("g-1"),
        pay("g-1", 4_000, "p-1"),
        reduce("p-1", 1_000, "r-1")
      ])

      entry = cash_entry(conn, "2026-10-06", "prop-1")
      assert entry["movements"]["reduced_cents"] == 1_000
      assert entry["opening_held_cents"] == 4_000
      assert entry["closing_held_cents"] == 3_000
    end

    test "transfer movements equal each other across properties", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      submit_batch(conn, [
        open("g-1", %{"property_id" => "prop-a", "operation_id" => "g-1-open"}),
        open("g-2", %{"property_id" => "prop-b", "operation_id" => "g-2-open"}),
        pay("g-1", 6_000, "p-1"),
        transfer("g-1", "g-2", 2_000, "t-1")
      ])

      source = cash_entry(conn, "2026-10-05", "prop-a")
      assert source["opening_held_cents"] == 6_000
      assert source["movements"]["transferred_out_cents"] == 2_000
      assert source["closing_held_cents"] == 4_000

      destination = cash_entry(conn, "2026-10-05", "prop-b")
      assert destination["opening_held_cents"] == 0
      assert destination["movements"]["transferred_in_cents"] == 2_000
      assert destination["closing_held_cents"] == 2_000

      %{"data" => %{"cash" => cash}} = report_ok(conn, "2026-10-05")

      assert cash
             |> Enum.map(& &1["movements"]["transferred_in_cents"])
             |> Enum.sum() ==
               cash
               |> Enum.map(& &1["movements"]["transferred_out_cents"])
               |> Enum.sum()

      # Hotel credit moved by a transfer has no cash movement column.
      submit_batch(conn, [
        open("g-3", %{"operation_id" => "g-3-open"}),
        apply_credit("g-3", 5_500, "2026-11-28", "apply-1")
      ])

      assert cash_entry(conn, "2026-11-28", "prop-1") == nil
    end

    test "omits properties with no opening, closing or movements", %{conn: conn} do
      submit_batch(conn, [
        start_reporting("start-1", "2026-10-01"),
        open("g-1"),
        pay("g-1", 2_000, "p-1")
      ])

      assert %{
               "data" => %{
                 "date" => "2026-10-03",
                 "status" => "open",
                 "cash" => [entry],
                 "credit" => %{
                   "opening_liability_cents" => 0,
                   "movements" => _credit_movements,
                   "closing_liability_cents" => 0
                 }
               }
             } = report_ok(conn, "2026-10-03")

      assert entry["property_id"] == "prop-1"
      assert entry["movements"]["received_cents"] == 2_000
    end

    test "cash entries are ordered by property_id", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      submit_batch(conn, [
        open("g-1", %{"property_id" => "prop-z", "operation_id" => "g-1-open"}),
        open("g-2", %{"property_id" => "prop-a", "operation_id" => "g-2-open"}),
        pay("g-1", 1_000, "p-1"),
        pay("g-2", 1_000, "p-2")
      ])

      %{"data" => %{"cash" => cash}} = report_ok(conn, "2026-10-03")
      assert Enum.map(cash, & &1["property_id"]) == ["prop-a", "prop-z"]
    end
  end

  describe "credit movements" do
    test "issued credit, later applications and passive expiry", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      submit_batch(conn, [
        open("g-1"),
        pay("g-1", 6_000, "p-1"),
        cancel("g-1", "2026-11-26", "c-1", %{"refund_method" => "hotel_credit"})
      ])

      issued_date = report_ok(conn, "2026-11-26")

      assert issued_date["data"]["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => %{
                 "issued_cents" => 6_600,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 6_600
             }

      entry = cash_entry(conn, "2026-11-26", "prop-1")
      assert entry["movements"]["converted_to_credit_cents"] == 6_000
      assert entry["closing_held_cents"] == 0

      # Applying credit redeems it into the deposit without moving liability.
      submit_batch(conn, [
        open("g-2"),
        apply_credit("g-2", 3_000, "2026-11-28", "apply-1")
      ])

      apply_date = report_ok(conn, "2026-11-28")

      assert apply_date["data"]["credit"]["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert apply_date["data"]["credit"]["closing_liability_cents"] == 6_600

      # The unused 3_600 expires the day after expires_on (2027-11-26),
      # even though no operation was submitted that day.
      expiry_date = report_ok(conn, "2027-11-27")

      assert expiry_date["data"]["credit"] == %{
               "opening_liability_cents" => 6_600,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 3_600,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 3_000
             }

      # Nothing expired on the lot's own expires_on.
      assert credit_movements(conn, "2027-11-26", "expired_cents") == 0

      # The closing liability equals credit applied to the active group.
      assert expiry_date["data"]["credit"]["closing_liability_cents"] == 3_000
    end

    test "non-refundable settlement consumes applied credit", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      submit_batch(conn, [
        open("g-1"),
        pay("g-1", 6_000, "p-1"),
        cancel("g-1", "2026-11-26", "c-1", %{"refund_method" => "hotel_credit"}),
        open("g-2", %{"arrival_on" => "2026-12-20", "departure_on" => "2026-12-23"}),
        apply_credit("g-2", 3_000, "2026-11-28", "apply-1"),
        cancel("g-2", "2026-12-10", "c-2")
      ])

      consumed = report_ok(conn, "2026-12-10")

      assert consumed["data"]["credit"]["movements"]["consumed_cents"] == 3_000
      assert consumed["data"]["credit"]["closing_liability_cents"] == 3_600

      assert credit_movements(conn, "2027-11-27", "expired_cents") == 3_600

      # Nothing had expired when the settlement posted, so that report's
      # closing liability matches the current ledger view.
      assert consumed["data"]["credit"]["closing_liability_cents"] ==
               ledger(conn)["data"]["credit_liability_cents"]

      assert report_ok(conn, "2027-11-27")["data"]["credit"]["closing_liability_cents"] == 0
    end

    test "a chargeback revokes the converted entitlement", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      submit_batch(conn, [
        open("g-1"),
        pay("g-1", 5_000, "p-1"),
        cancel("g-1", "2026-11-20", "c-1", %{"refund_method" => "hotel_credit"}),
        charge_back("p-1", "cb-1", "2026-11-21")
      ])

      charged = report_ok(conn, "2026-11-21")

      assert charged["data"]["credit"] == %{
               "opening_liability_cents" => 5_500,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 5_500,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 0
             }

      entry = cash_entry(conn, "2026-11-21", "prop-1")
      assert entry["movements"]["converted_to_credit_cents"] == -5_000
      assert entry["movements"]["charged_back_cents"] == 5_000
    end

    test "a revocation after the lot expiry is covered by the expiry itself", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      submit_batch(conn, [
        open("g-1"),
        pay("g-1", 5_000, "p-1"),
        cancel("g-1", "2026-11-26", "c-1", %{"refund_method" => "hotel_credit"}),
        charge_back("p-1", "cb-1", "2027-12-01")
      ])

      # The lot's remaining credit expired on 2027-11-27 before the
      # chargeback posted, so the revocation adds no liability movement.
      expiry = report_ok(conn, "2027-11-27")["data"]["credit"]
      assert expiry["movements"]["expired_cents"] == 5_500
      assert expiry["closing_liability_cents"] == 0

      charged = report_ok(conn, "2027-12-01")["data"]["credit"]
      assert charged["movements"]["revoked_cents"] == 0
      assert charged["opening_liability_cents"] == 0
      assert charged["closing_liability_cents"] == 0

      entry = cash_entry(conn, "2027-12-01", "prop-1")
      assert entry["movements"]["converted_to_credit_cents"] == -5_000
      assert entry["movements"]["charged_back_cents"] == 5_000

      assert ledger(conn)["data"]["credit_liability_cents"] == 0
    end

    test "a restoration extinguishes the unrecovered clawback as absorption", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      submit_batch(conn, [
        open("g-1"),
        pay("g-1", 5_000, "p-1"),
        cancel("g-1", "2026-11-20", "c-1", %{"refund_method" => "hotel_credit"}),
        open("g-2", %{"arrival_on" => "2027-01-10", "departure_on" => "2027-01-13"}),
        apply_credit("g-2", 3_000, "2026-11-22", "apply-1"),
        charge_back("p-1", "cb-1", "2026-11-23"),
        cancel("g-2", "2026-11-25", "c-2")
      ])

      # The chargeback could only remove the lot's remaining 2_500.
      assert report_ok(conn, "2026-11-23")["data"]["credit"]["movements"]["revoked_cents"] ==
               2_500

      restored = report_ok(conn, "2026-11-25")

      assert restored["data"]["credit"]["movements"]["absorbed_cents"] == 3_000
      assert restored["data"]["credit"]["closing_liability_cents"] == 0

      assert ledger(conn)["data"]["credit_shortfall_cents"] == 0
    end

    test "a lot issuing after its expiry date reports issue and expiry together", %{
      conn: conn
    } do
      submit_batch(conn, [start_reporting("start-1", "2028-06-01", "2028-06-01")])

      # The cancellation predates both its own expiry (2027-05-11) and the
      # reporting start, so its credit expiry makes the issuance a no-op.
      submit_batch(conn, [
        open("g-1", %{
          "operation_id" => "g-1-open",
          "occurred_on" => "2026-05-01",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13"
        }),
        pay("g-1", 5_000, "p-1", "2026-05-02"),
        cancel("g-1", "2026-05-10", "c-1", %{"refund_method" => "hotel_credit"})
      ])

      first_day = report_ok(conn, "2028-06-01")["data"]["credit"]

      assert first_day["movements"] == %{
               "issued_cents" => 5_500,
               "expired_cents" => 5_500,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert first_day["closing_liability_cents"] == 0

      entry = cash_entry(conn, "2028-06-01", "prop-1")
      assert entry["movements"]["converted_to_credit_cents"] == 5_000

      assert report_ok(conn, "2028-06-02")["data"]["credit"]["closing_liability_cents"] == 0
    end

    test "a restoration after the lot expiry records an expiry movement", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      submit_batch(conn, [
        open("g-1"),
        pay("g-1", 5_000, "p-1"),
        cancel("g-1", "2026-11-26", "c-1", %{"refund_method" => "hotel_credit"}),
        open("g-2", %{"arrival_on" => "2028-12-20", "departure_on" => "2028-12-23"}),
        apply_credit("g-2", 3_000, "2026-11-28", "apply-1"),
        cancel("g-2", "2027-11-29", "c-2")
      ])

      # The lot expired on 2027-11-27; the restoration expires immediately.
      after_expiry = report_ok(conn, "2027-11-29")

      assert after_expiry["data"]["credit"]["movements"]["expired_cents"] == 3_000
      assert after_expiry["data"]["credit"]["opening_liability_cents"] == 3_000
      assert after_expiry["data"]["credit"]["closing_liability_cents"] == 0

      # The unused available balance expired the day after expires_on.
      assert credit_movements(conn, "2027-11-27", "expired_cents") == 2_500
    end
  end

  describe "report reconciliation" do
    test "closing balances equal the current ledger views", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      submit_batch(conn, [
        open("g-1"),
        open("g-2", %{"property_id" => "prop-b", "operation_id" => "g-2-open"}),
        pay("g-1", 6_000, "p-1"),
        transfer("g-1", "g-2", 2_000, "t-1"),
        pay("g-2", 4_000, "p-2"),
        reduce("p-2", 1_000, "r-1"),
        cancel("g-1", "2026-11-20", "c-1", %{"refund_method" => "hotel_credit"})
      ])

      report = report_ok(conn, "2026-11-20")["data"]

      assert Enum.map(report["cash"], & &1["property_id"]) == ["prop-1", "prop-b"]

      assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
               ledger(conn)["data"]["cash_held_cents"]

      assert report["credit"]["closing_liability_cents"] ==
               ledger(conn)["data"]["credit_liability_cents"]

      assert report["credit"]["movements"]["issued_cents"] == 4_400

      # `prop-b` held 4_000 - 1_000 reduction + 2_000 transferred = 5_000.
      assert cash_entry(conn, "2026-11-20", "prop-b")["closing_held_cents"] == 5_000
      # `prop-1` converted its 4_000 held cash into credit.
      assert cash_entry(conn, "2026-11-20", "prop-1")["closing_held_cents"] == 0

      assert cash_entry(conn, "2026-11-20", "prop-1")["movements"][
               "converted_to_credit_cents"
             ] == 4_000
    end

    test "rejected operations leave no movements and retries never double-report", %{
      conn: conn
    } do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      # A payment against a missing group is rejected and leaves no movement.
      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               submit_batch(conn, [pay("g-1", 2_000, "p-rejected")])

      assert cash_entry(conn, "2026-10-03", "prop-1") == nil

      pay_op = pay("g-1", 2_000, "p-1")

      assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
               submit_batch(conn, [open("g-1"), pay_op])

      entry = cash_entry(conn, "2026-10-03", "prop-1")
      assert entry["movements"]["received_cents"] == 2_000

      # Retrying the payment returns the stored result and reports nothing new.
      assert %{"results" => [%{"status" => "applied"}]} = submit_batch(conn, [pay_op])
      assert cash_entry(conn, "2026-10-03", "prop-1")["movements"]["received_cents"] == 2_000
    end

    test "later submissions can change an earlier open report", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      submit_batch(conn, [
        open("g-1"),
        pay("g-1", 1_000, "p-1", "2026-10-03")
      ])

      assert cash_entry(conn, "2026-10-03", "prop-1")["movements"]["received_cents"] == 1_000

      # A backdated payment resubmitted later lands in the earlier report.
      submit_batch(conn, [pay("g-1", 500, "p-2", "2026-10-02")])

      entry = cash_entry(conn, "2026-10-02", "prop-1")
      assert entry["movements"]["received_cents"] == 500
    end

    test "equivalent batches and sequential submissions produce equivalent reports", %{
      conn: conn
    } do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      # Opening and payment in one batch.
      submit_batch(conn, [
        open("g-x1"),
        pay("g-x1", 2_000, "p-x1", "2026-10-03")
      ])

      one_batch = report_ok(conn, "2026-10-03")

      assert one_batch["data"]["cash"]
             |> List.first()
             |> Map.fetch!("movements")
             |> Map.fetch!("received_cents") == 2_000

      # The same events submitted later, one per batch: the earlier report is
      # not disturbed and the new payment appears on its own posting date.
      submit_batch(conn, [open("g-y1")])
      submit_batch(conn, [pay("g-y1", 2_000, "p-y1", "2026-10-04")])

      assert report_ok(conn, "2026-10-03") == one_batch

      assert cash_entry(conn, "2026-10-04", "prop-1")["movements"]["received_cents"] == 2_000
    end

    test "movements from earlier applied operations survive a later rejection", %{conn: conn} do
      submit_batch(conn, [
        start_reporting("start-1", "2026-10-01"),
        open("g-1"),
        pay("g-1", 2_000, "p-1"),
        pay("missing", 500, "p-broken")
      ])

      # The last operation was rejected but the earlier movements remain.
      entry = cash_entry(conn, "2026-10-03", "prop-1")
      assert entry["movements"]["received_cents"] == 2_000
      assert entry["closing_held_cents"] == 2_000
    end
  end
end
