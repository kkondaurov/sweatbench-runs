defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp post_batch(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(payload))
  end

  defp submit(conn, operations) do
    conn
    |> post_batch(%{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit_one(conn, operation) do
    [result] = submit(conn, [operation])
    result
  end

  # Two flexible rooms, 3 nights: room-a due 9000 (15000/night), room-b due
  # 10500 (17500/night); the deposit due is 19500. Booked 2026-10-03, so the
  # flex-14 policy leaves cancellations refundable through 2026-11-26.
  defp open_operation(group_id, guest_id, property_id) do
    %{
      "operation_id" => unique_id("open"),
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => property_id,
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
      ]
    }
  end

  @doc false
  def unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp open_group!(conn, group_id, guest_id \\ "guest-22", property_id \\ "ams-canal") do
    result = submit_one(conn, open_operation(group_id, guest_id, property_id))
    assert result["status"] == "applied"
    result
  end

  defp pay!(conn, group_id, amount_cents, occurred_on \\ "2026-11-15") do
    result =
      submit_one(conn, %{
        "operation_id" => unique_id("pay"),
        "type" => "record_cash_payment",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "amount_cents" => amount_cents
      })

    assert result["status"] == "applied"
    result
  end

  # Pays with a fixed operation identifier so reductions and chargebacks can
  # address it; returns the operation id.
  defp pay_named!(conn, operation_id, group_id, amount_cents, occurred_on \\ "2026-11-15") do
    result =
      submit_one(conn, %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "amount_cents" => amount_cents
      })

    assert result["status"] == "applied"
    operation_id
  end

  defp start_reporting(conn, starts_on, operation_id \\ unique_id("start")) do
    submit_one(conn, %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    })
  end

  defp start_reporting!(conn, starts_on) do
    result = start_reporting(conn, starts_on)
    assert result["status"] == "applied"
    result
  end

  defp daily_report(conn, date) do
    conn |> get(~p"/api/v1/finance/daily-report?date=#{date}")
  end

  defp report!(conn, date) do
    conn |> daily_report(date) |> json_response(200) |> Map.fetch!("data")
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  defp zero_movements(fields) do
    Map.new(fields, &{&1, 0})
  end

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  describe "start_finance_reporting" do
    test "the applied result contains exactly operation_id, status, and starts_on", %{conn: conn} do
      result = start_reporting(conn, "2026-12-01", "start-1")

      assert result == %{
               "operation_id" => "start-1",
               "status" => "applied",
               "starts_on" => "2026-12-01"
             }
    end

    test "a missing, malformed, or non-date starts_on is invalid_reporting_date", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "invalid_reporting_date"} =
               start_reporting(conn, nil)

      assert %{"status" => "rejected", "code" => "invalid_reporting_date"} =
               start_reporting(conn, "2026-13-01")

      assert %{"status" => "rejected", "code" => "invalid_reporting_date"} =
               start_reporting(conn, "not-a-date")
    end

    test "once reporting has started, a different start operation is rejected", %{conn: conn} do
      start_reporting!(conn, "2026-12-01")

      assert %{"status" => "rejected", "code" => "reporting_already_started"} =
               start_reporting(conn, "2027-01-15")
    end

    test "a retry of the original start returns the stored result", %{conn: conn} do
      first = start_reporting(conn, "2026-12-01", "start-original")
      assert first["status"] == "applied"
      assert start_reporting(conn, "2026-12-01", "start-original") == first
    end

    test "in the same batch, operations before the start open the position and ones after it move",
         %{conn: conn} do
      [open_result, pay_result, start_result, pay2_result] =
        submit(conn, [
          %{
            "operation_id" => "open-1",
            "type" => "open_group",
            "occurred_on" => "2026-10-03",
            "group_id" => "group-81",
            "guest_id" => "guest-22",
            "property_id" => "ams-canal",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-13",
            "rate_plan" => "flexible",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
          },
          %{
            "operation_id" => "pay-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-11-30",
            "group_id" => "group-81",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "start-1",
            "type" => "start_finance_reporting",
            "starts_on" => "2026-12-01"
          },
          %{
            "operation_id" => "pay-2",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-12-02",
            "group_id" => "group-81",
            "amount_cents" => 500
          }
        ])

      assert open_result["status"] == "applied"
      assert pay_result["status"] == "applied"
      assert start_result["status"] == "applied"
      assert pay2_result["status"] == "applied"

      entry = cash_entry(report!(conn, "2026-12-01"), "ams-canal")
      assert entry["opening_held_cents"] == 1000
      assert entry["movements"] == zero_movements(@cash_fields)
      assert entry["closing_held_cents"] == 1000

      entry = cash_entry(report!(conn, "2026-12-02"), "ams-canal")
      assert entry["movements"]["received_cents"] == 500
      assert entry["closing_held_cents"] == 1500
    end

    test "operations committed before the start are in the opening even when their dates follow starts_on",
         %{conn: conn} do
      open_group!(conn, "group-81")
      pay!(conn, "group-81", 1000, "2027-02-10")

      start_reporting!(conn, "2027-02-01")

      entry = cash_entry(report!(conn, "2027-02-01"), "ams-canal")
      assert entry["opening_held_cents"] == 1000
      assert entry["movements"] == zero_movements(@cash_fields)
      assert entry["closing_held_cents"] == 1000
    end
  end

  describe "GET /api/v1/finance/daily-report" do
    test "before reporting has started, the report is not available", %{conn: conn} do
      assert daily_report(conn, "2026-12-01") |> json_response(404) == %{
               "error" => %{"code" => "report_not_available"}
             }
    end

    test "a date before starts_on is not available", %{conn: conn} do
      start_reporting!(conn, "2026-12-01")

      assert daily_report(conn, "2026-11-30") |> json_response(404) == %{
               "error" => %{"code" => "report_not_available"}
             }
    end

    test "a missing or invalid date is invalid_reporting_date", %{conn: conn} do
      start_reporting!(conn, "2026-12-01")

      assert conn |> get("/api/v1/finance/daily-report") |> json_response(422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }

      assert daily_report(conn, "2026-13-40") |> json_response(422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }
    end

    test "a successful report is open with a per-property cash array and one credit object", %{
      conn: conn
    } do
      start_reporting!(conn, "2026-12-01")

      assert report!(conn, "2026-12-01") == %{
               "date" => "2026-12-01",
               "status" => "open",
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_movements(@credit_fields),
                 "closing_liability_cents" => 0
               }
             }
    end

    test "the cash array is ordered by property_id and omits only all-zero properties", %{
      conn: conn
    } do
      open_group!(conn, "group-a", "guest-22", "zzz-last")
      open_group!(conn, "group-b", "guest-22", "ams-canal")
      start_reporting!(conn, "2026-12-01")

      # zzz-last received and refunded in full on the same day: both its
      # balances are zero but its movements are not, so it stays listed.
      pay!(conn, "group-a", 19500, "2026-12-01")
      pay!(conn, "group-b", 5000, "2026-12-01")

      submit_one(conn, %{
        "operation_id" => "cancel-a",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-a",
        "refund_method" => "cash"
      })

      report = report!(conn, "2026-12-01")
      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "zzz-last"]

      entry = cash_entry(report, "zzz-last")
      assert entry["movements"]["received_cents"] == 19500
      assert entry["movements"]["refunded_cents"] == 19500
      assert entry["opening_held_cents"] == 0
      assert entry["closing_held_cents"] == 0
    end
  end

  describe "cash movements" do
    test "payments and refundable settlements move held cash on their posting dates", %{
      conn: conn
    } do
      open_group!(conn, "group-81")
      pay!(conn, "group-81", 10000)

      start_reporting!(conn, "2026-12-01")

      pay!(conn, "group-81", 5000, "2026-12-01")

      entry = cash_entry(report!(conn, "2026-12-01"), "ams-canal")
      assert entry["opening_held_cents"] == 10000
      assert entry["movements"]["received_cents"] == 5000
      assert entry["closing_held_cents"] == 15000

      # Refundable because the operation occurred within the flex-14 window;
      # processed after the start, it clamps to posting on 2026-12-01.
      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "refund_method" => "cash"
      })

      entry = cash_entry(report!(conn, "2026-12-01"), "ams-canal")
      assert entry["movements"]["refunded_cents"] == 15000
      assert entry["closing_held_cents"] == 0
    end

    test "a non-refundable cancellation retains the cash", %{conn: conn} do
      open_group!(conn, "group-81")
      pay!(conn, "group-81", 9000)
      start_reporting!(conn, "2026-12-01")

      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-04",
        "group_id" => "group-81"
      })

      entry = cash_entry(report!(conn, "2026-12-04"), "ams-canal")
      assert entry["movements"]["retained_cents"] == 9000
      assert entry["movements"]["refunded_cents"] == 0
      assert entry["closing_held_cents"] == 0
    end

    test "reductions and chargebacks move held cash on their own posting dates", %{conn: conn} do
      open_group!(conn, "group-81")
      pay!(conn, "group-81", 5000)
      pay1 = pay_named!(conn, "pay-target", "group-81", 4000)

      start_reporting!(conn, "2026-12-01")

      submit_one(conn, %{
        "operation_id" => "reduce-1",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-12-05",
        "payment_operation_id" => pay1,
        "amount_cents" => 1000
      })

      submit_one(conn, %{
        "operation_id" => "chargeback-1",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-12-06",
        "payment_operation_id" => pay1
      })

      assert cash_entry(report!(conn, "2026-12-05"), "ams-canal")["movements"]["reduced_cents"] ==
               1000

      entry = cash_entry(report!(conn, "2026-12-06"), "ams-canal")
      assert entry["movements"]["charged_back_cents"] == 3000
      assert entry["closing_held_cents"] == 5000
    end

    test "a late operation whose occurred_on precedes starts_on posts on starts_on", %{conn: conn} do
      open_group!(conn, "group-81")
      start_reporting!(conn, "2026-12-01")

      pay!(conn, "group-81", 1000, "2026-11-15")

      entry = cash_entry(report!(conn, "2026-12-01"), "ams-canal")
      assert entry["movements"]["received_cents"] == 1000
      assert entry["closing_held_cents"] == 1000
    end

    test "transfers move cash between the source and destination properties", %{conn: conn} do
      open_group!(conn, "group-81", "guest-22", "ams-canal")
      open_group!(conn, "group-92", "guest-22", "rhs-plaza")
      pay!(conn, "group-81", 10000)
      start_reporting!(conn, "2026-12-01")

      submit_one(conn, %{
        "operation_id" => "transfer-1",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-12-02",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 4000
      })

      report = report!(conn, "2026-12-02")
      ams = cash_entry(report, "ams-canal")
      rhs = cash_entry(report, "rhs-plaza")

      assert ams["opening_held_cents"] == 10000
      assert ams["movements"]["transferred_out_cents"] == 4000
      assert ams["movements"]["transferred_in_cents"] == 0
      assert ams["closing_held_cents"] == 6000

      assert rhs["opening_held_cents"] == 0
      assert rhs["movements"]["transferred_in_cents"] == 4000
      assert rhs["movements"]["transferred_out_cents"] == 0
      assert rhs["closing_held_cents"] == 4000

      transferred_in =
        Enum.sum(for entry <- report["cash"], do: entry["movements"]["transferred_in_cents"])

      transferred_out =
        Enum.sum(for entry <- report["cash"], do: entry["movements"]["transferred_out_cents"])

      assert transferred_in == transferred_out
    end

    test "a correction follows the cash to the property where it is held or was settled", %{
      conn: conn
    } do
      open_group!(conn, "group-81", "guest-22", "ams-canal")
      open_group!(conn, "group-92", "guest-22", "rhs-plaza")
      pay1 = pay_named!(conn, "pay-1", "group-81", 10000)

      submit_one(conn, %{
        "operation_id" => "transfer-1",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-15",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 4000
      })

      # Settle the transferred portion at the destination property.
      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => "group-92",
        "refund_method" => "cash"
      })

      start_reporting!(conn, "2026-12-01")

      submit_one(conn, %{
        "operation_id" => "chargeback-1",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-12-03",
        "payment_operation_id" => pay1
      })

      report = report!(conn, "2026-12-03")
      ams = cash_entry(report, "ams-canal")
      rhs = cash_entry(report, "rhs-plaza")

      # The still-held 6000 leaves ams-canal's held balance. The 4000 already
      # refunded at rhs-plaza is reclassified: negative refunded together with
      # positive charged-back, so rhs-plaza's held balance does not move.
      assert ams["movements"]["charged_back_cents"] == 6000
      assert rhs["movements"]["charged_back_cents"] == 4000
      assert rhs["movements"]["refunded_cents"] == -4000
      assert rhs["opening_held_cents"] == 0
      assert rhs["closing_held_cents"] == 0
      assert ams["opening_held_cents"] == 6000
      assert ams["closing_held_cents"] == 0
    end

    test "rejected operations leave no movement, and an exact retry does not report twice", %{
      conn: conn
    } do
      open_group!(conn, "group-81")
      start_reporting!(conn, "2026-12-01")

      bad = %{
        "operation_id" => "pay-bad",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "amount_cents" => 0
      }

      assert submit_one(conn, bad)["status"] == "rejected"

      operation = %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "amount_cents" => 1000
      }

      first = submit_one(conn, operation)
      assert first["status"] == "applied"
      assert submit_one(conn, operation) == first

      entry = cash_entry(report!(conn, "2026-12-01"), "ams-canal")
      assert entry["movements"]["received_cents"] == 1000
      assert entry["closing_held_cents"] == 1000
    end
  end

  describe "credit movements" do
    test "conversion issues liability; application has no column; non-refundable settlement consumes it",
         %{conn: conn} do
      open_group!(conn, "group-81")
      pay!(conn, "group-81", 10000)
      start_reporting!(conn, "2026-12-01")

      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "refund_method" => "hotel_credit"
      })

      report = report!(conn, "2026-12-01")
      ams = cash_entry(report, "ams-canal")
      assert ams["movements"]["converted_to_credit_cents"] == 10000

      credit = report["credit"]
      assert credit["opening_liability_cents"] == 0
      assert credit["movements"]["issued_cents"] == 11000
      assert credit["closing_liability_cents"] == 11000

      open_group!(conn, "group-92")

      submit_one(conn, %{
        "operation_id" => "apply-1",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-02",
        "group_id" => "group-92",
        "amount_cents" => 11000
      })

      report = report!(conn, "2026-12-02")
      assert report["credit"]["movements"] == zero_movements(@credit_fields)
      assert report["credit"]["closing_liability_cents"] == 11000

      submit_one(conn, %{
        "operation_id" => "cancel-2",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-27",
        "group_id" => "group-92"
      })

      report = report!(conn, "2026-12-27")
      assert report["credit"]["movements"]["consumed_cents"] == 11000
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "a chargeback revokes unspent entitlement; a later restoration absorbs the shortfall first",
         %{conn: conn} do
      # Two payments converted into one 17600 lot; the lot is fully spent, so
      # the first payment's 8800 entitlement becomes an unrecovered clawback.
      open_group!(conn, "group-81")
      pay1 = pay_named!(conn, "pay-1", "group-81", 8000)
      pay!(conn, "group-81", 8000)

      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "refund_method" => "hotel_credit"
      })

      open_group!(conn, "group-82")

      submit_one(conn, %{
        "operation_id" => "apply-1",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-82",
        "amount_cents" => 17600
      })

      start_reporting!(conn, "2026-12-01")

      submit_one(conn, %{
        "operation_id" => "chargeback-1",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-12-02",
        "payment_operation_id" => pay1
      })

      # Nothing was left in the lot, so no liability left through revocation
      # yet; the applied credit still counts toward the liability.
      report = report!(conn, "2026-12-02")
      assert report["credit"]["movements"]["revoked_cents"] == 0
      assert report["credit"]["closing_liability_cents"] == 17600

      # Refundable settlement returns the credit to the shortfalled lot; the
      # first 8800 of the return absorbs the clawback instead of becoming
      # available again.
      submit_one(conn, %{
        "operation_id" => "cancel-2",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-82",
        "refund_method" => "cash"
      })

      report = report!(conn, "2026-12-01")
      assert report["credit"]["movements"]["absorbed_cents"] == 8800
      # 17600 (opening of 12-01 minus nothing yet) minus the absorbed 8800.
      assert report["credit"]["closing_liability_cents"] == 8800
    end

    test "credit that remains unused through its expires_on date expires on the following date",
         %{conn: conn} do
      open_group!(conn, "group-81")
      pay!(conn, "group-81", 10000)

      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "refund_method" => "hotel_credit"
      })

      # Expires on 2027-11-26; it expires on 2027-11-27.

      start_reporting!(conn, "2026-12-01")

      report = report!(conn, "2027-11-26")
      assert report["credit"]["movements"]["expired_cents"] == 0
      assert report["credit"]["closing_liability_cents"] == 11000

      report = report!(conn, "2027-11-27")
      assert report["credit"]["movements"]["expired_cents"] == 11000
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "an application reduces what a lot has left to expire", %{conn: conn} do
      open_group!(conn, "group-81")
      pay!(conn, "group-81", 10000)

      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "refund_method" => "hotel_credit"
      })

      open_group!(conn, "group-82")

      submit_one(conn, %{
        "operation_id" => "apply-1",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-20",
        "group_id" => "group-82",
        "amount_cents" => 3000
      })

      start_reporting!(conn, "2026-12-01")

      report = report!(conn, "2027-11-27")
      assert report["credit"]["movements"]["expired_cents"] == 8000
      assert report["credit"]["closing_liability_cents"] == 3000
    end

    test "credit restored to a lot whose expiry already passed expires on the restore's posting date", %{conn: conn} do
      # Issue a lot on 2026-11-26; it expires on 2027-11-26. Apply it to a
      # group arriving more than a year away and cancel it refundably (in
      # cash) after that expiry: the restored amount expires immediately
      # instead of becoming available again.
      open_group!(conn, "group-81")
      pay!(conn, "group-81", 10000, "2026-11-15")

      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "refund_method" => "hotel_credit"
      })

      far_future =
        open_operation("group-82", "guest-22", "ams-canal")
        |> Map.merge(%{
          "arrival_on" => "2028-01-01",
          "departure_on" => "2028-01-03"
        })

      assert submit_one(conn, far_future)["status"] == "applied"

      submit_one(conn, %{
        "operation_id" => "apply-1",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-20",
        "group_id" => "group-82",
        "amount_cents" => 11000
      })

      start_reporting!(conn, "2027-06-01")

      # Refundable until 2027-12-18 under the flex-14 policy; on 2027-11-27
      # the lot's 2027-11-26 expiry has already passed.
      submit_one(conn, %{
        "operation_id" => "cancel-2",
        "type" => "cancel_group",
        "occurred_on" => "2027-11-27",
        "group_id" => "group-82",
        "refund_method" => "cash"
      })

      report = report!(conn, "2027-11-27")
      assert report["credit"]["movements"]["expired_cents"] == 11000
      assert report["credit"]["movements"]["absorbed_cents"] == 0
      assert report["credit"]["closing_liability_cents"] == 0

      # The natural expiry date also reports nothing: the liability was still
      # applied to the group, so nothing remained unused to expire.
      report = report!(conn, "2027-11-30")
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "a revoked entitlement reduces what a lot has left to expire", %{conn: conn} do
      open_group!(conn, "group-81")
      pay1 = pay_named!(conn, "pay-1", "group-81", 5000)
      pay!(conn, "group-81", 5000)

      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "refund_method" => "hotel_credit"
      })

      # Lot 11000 with two entitlements of 5500 each.

      submit_one(conn, %{
        "operation_id" => "chargeback-1",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-27",
        "payment_operation_id" => pay1
      })

      start_reporting!(conn, "2026-12-01")

      report = report!(conn, "2027-11-27")
      # 5500 was revoked on 2026-11-27, so only 5500 remains to expire.
      assert report["credit"]["movements"]["expired_cents"] == 5500
      assert report["credit"]["closing_liability_cents"] == 0
    end
  end

  describe "reconciliation" do
    test "closing balances reconcile to the current ledger view, in any read order", %{conn: conn} do
      open_group!(conn, "group-81", "guest-22", "ams-canal")
      open_group!(conn, "group-92", "guest-22", "rhs-plaza")
      pay!(conn, "group-81", 10000)

      start_reporting!(conn, "2026-12-01")

      pay!(conn, "group-92", 7000, "2026-12-02")

      submit_one(conn, %{
        "operation_id" => "transfer-1",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-12-03",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 4000
      })

      # Read out of order and repeatedly: state never changes.
      latest = report!(conn, "2026-12-03")
      _earlier = report!(conn, "2026-12-02")
      latest_again = report!(conn, "2026-12-03")

      assert latest == latest_again

      ledger =
        conn
        |> get(~p"/api/v1/ledger?on=2026-12-03")
        |> json_response(200)
        |> Map.fetch!("data")

      closing_held = Enum.sum(for entry <- latest["cash"], do: entry["closing_held_cents"])
      assert closing_held == ledger["cash_held_cents"]
      assert latest["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]
    end

    test "chargebacks that reclassify settled cash reconcile to ledger held cash", %{conn: conn} do
      open_group!(conn, "group-81", "guest-22", "ams-canal")
      pay1 = pay_named!(conn, "pay-1", "group-81", 10000)

      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "refund_method" => "cash"
      })

      start_reporting!(conn, "2026-12-01")

      submit_one(conn, %{
        "operation_id" => "chargeback-1",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-12-03",
        "payment_operation_id" => pay1
      })

      report = report!(conn, "2026-12-03")
      ams = cash_entry(report, "ams-canal")
      assert ams["movements"]["refunded_cents"] == -10000
      assert ams["movements"]["charged_back_cents"] == 10000

      ledger =
        conn
        |> get(~p"/api/v1/ledger?on=2026-12-03")
        |> json_response(200)
        |> Map.fetch!("data")

      closing_held = Enum.sum(for entry <- report["cash"], do: entry["closing_held_cents"])
      assert closing_held == ledger["cash_held_cents"]

      # Refunded post-start, then charged back: same reclassification shape.
      open_group!(conn, "group-82")
      pay2 = pay_named!(conn, "pay-2", "group-82", 5000, "2026-12-01")

      submit_one(conn, %{
        "operation_id" => "cancel-2",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-82",
        "refund_method" => "cash"
      })

      submit_one(conn, %{
        "operation_id" => "chargeback-2",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-12-04",
        "payment_operation_id" => pay2
      })

      report = report!(conn, "2026-12-04")
      ams = cash_entry(report, "ams-canal")
      assert ams["opening_held_cents"] == 0
      assert ams["movements"]["refunded_cents"] == -5000
      assert ams["movements"]["charged_back_cents"] == 5000
      assert ams["closing_held_cents"] == 0

      closing_held = Enum.sum(for entry <- report["cash"], do: entry["closing_held_cents"])

      ledger =
        conn
        |> get(~p"/api/v1/ledger?on=2026-12-04")
        |> json_response(200)
        |> Map.fetch!("data")

      assert closing_held == ledger["cash_held_cents"]
    end

    test "operations submitted in one batch produce the report the sequential equivalent does", %{
      conn: conn
    } do
      [open_result, pay_result, start_result, pay2_result] =
        submit(conn, [
          %{
            "operation_id" => "open-1",
            "type" => "open_group",
            "occurred_on" => "2026-10-03",
            "group_id" => "group-81",
            "guest_id" => "guest-22",
            "property_id" => "ams-canal",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-13",
            "rate_plan" => "flexible",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
          },
          %{
            "operation_id" => "pay-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-11-15",
            "group_id" => "group-81",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "start-1",
            "type" => "start_finance_reporting",
            "starts_on" => "2026-12-01"
          },
          %{
            "operation_id" => "pay-2",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-12-02",
            "group_id" => "group-81",
            "amount_cents" => 500
          }
        ])

      for result <- [open_result, pay_result, start_result, pay2_result] do
        assert result["status"] == "applied"
      end

      assert report!(conn, "2026-12-02") == %{
               "date" => "2026-12-02",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 1000,
                   "movements" =>
                     Map.merge(zero_movements(@cash_fields), %{"received_cents" => 500}),
                   "closing_held_cents" => 1500
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_movements(@credit_fields),
                 "closing_liability_cents" => 0
               }
             }
    end
  end
end
