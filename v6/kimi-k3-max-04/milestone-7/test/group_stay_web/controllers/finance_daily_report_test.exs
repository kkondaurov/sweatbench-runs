defmodule GroupStayWeb.FinanceDailyReportTest do
  @moduledoc """
  `start_finance_reporting` and the daily finance report
  (docs/requests/06-daily-finance-report.md).

  Scenario groups use one room at rate 3000 for one night, so the deposit
  due is 600 per group.
  """
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit_one(conn, operation) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: [operation]})
    |> json_response(200)
    |> get_in(["results"])
    |> hd()
  end

  defp applied!(result) do
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp report(conn, date) do
    conn
    |> get(~p"/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get(~p"/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp next_id, do: "op-#{System.unique_integer([:positive])}"

  defp open_op(group_id, guest_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 3000}]
      },
      overrides
    )
  end

  defp pay_op(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "record_cash_payment",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp credit_op(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp cancel_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id
      },
      overrides
    )
  end

  defp transfer_op(source_id, destination_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "transfer_deposit",
        "source_group_id" => source_id,
        "destination_group_id" => destination_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp start_op(starts_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "start_finance_reporting",
        "starts_on" => starts_on
      },
      overrides
    )
  end

  describe "start_finance_reporting" do
    test "applies with exactly operation_id, status, and starts_on", %{conn: conn} do
      result = applied!(submit_one(conn, start_op("2026-10-10")))

      assert result == %{
               "operation_id" => result["operation_id"],
               "status" => "applied",
               "starts_on" => "2026-10-10"
             }
    end

    test "rejects a second, different start as reporting_already_started", %{conn: conn} do
      applied!(submit_one(conn, start_op("2026-10-10")))

      rejected = submit_one(conn, start_op("2026-11-01"))
      assert %{"status" => "rejected", "code" => "reporting_already_started"} = rejected
    end

    test "rejects missing or invalid starts_on as invalid_reporting_date", %{conn: conn} do
      missing = start_op(nil) |> Map.delete("starts_on")

      assert %{"status" => "rejected", "code" => "invalid_reporting_date"} =
               submit_one(conn, missing)

      assert %{"status" => "rejected", "code" => "invalid_reporting_date"} =
               submit_one(conn, start_op("not-a-date"))

      assert %{"status" => "rejected", "code" => "invalid_reporting_date"} =
               submit_one(conn, start_op("2026-13-01"))
    end

    test "a retry returns the exact stored result; a different payload conflicts", %{conn: conn} do
      op = start_op("2026-10-10")
      done = applied!(submit_one(conn, op))

      assert submit_one(conn, op) == done

      conflict =
        submit_one(conn, %{
          start_op("2026-11-01")
          | "operation_id" => op["operation_id"]
        })

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} = conflict
    end

    test "the state immediately before the start is the opening position", %{conn: conn} do
      # Funding committed before the start, even with occurred_on after
      # starts_on, belongs to the opening position and not the day's movements.
      pre_group = "pre-open"

      results =
        submit(conn, [
          open_op(pre_group, "guest-22"),
          pay_op(pre_group, 500, %{"occurred_on" => "2026-11-26"}),
          start_op("2026-10-10")
        ])

      Enum.each(results, &applied!/1)

      data = report(conn, "2026-10-10")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 500,
                 "movements" => movements,
                 "closing_held_cents" => 500
               }
             ] = data["cash"]

      assert movements == %{
               "received_cents" => 0,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
    end
  end

  describe "GET /api/v1/finance/daily-report errors" do
    test "missing or invalid date is 422 invalid_reporting_date", %{conn: conn} do
      response = get(conn, ~p"/api/v1/finance/daily-report")
      assert json_response(response, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      response = get(conn, ~p"/api/v1/finance/daily-report?date=2026-13-40")
      assert json_response(response, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "before reporting starts and before starts_on, 404 report_not_available", %{conn: conn} do
      response = get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-10")
      assert json_response(response, 404) == %{"error" => %{"code" => "report_not_available"}}

      applied!(submit_one(conn, start_op("2026-10-10")))

      response = get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-09")
      assert json_response(response, 404) == %{"error" => %{"code" => "report_not_available"}}
    end
  end

  describe "cash reporting" do
    test "reports received cash per property with the closing equation", %{conn: conn} do
      group = "cash-a"

      applied!(submit_one(conn, start_op("2026-10-10")))
      applied!(submit_one(conn, open_op(group, "guest-22")))
      applied!(submit_one(conn, pay_op(group, 500, %{"occurred_on" => "2026-10-12"})))

      data = report(conn, "2026-10-12")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{"received_cents" => 500},
                 "closing_held_cents" => 500
               }
             ] = data["cash"]

      assert %{"status" => "open", "date" => "2026-10-12"} = data

      assert Map.keys(data) |> Enum.sort() == [
               "cash",
               "credit",
               "date",
               "late_adjustments",
               "status"
             ]
    end

    test "a property with no balance and no movements is omitted", %{conn: conn} do
      applied!(submit_one(conn, start_op("2026-10-10")))
      applied!(submit_one(conn, open_op("no-cash", "guest-22")))

      data = report(conn, "2026-10-10")
      assert data["cash"] == []
    end

    test "transfers balance across properties and sort the cash list", %{conn: conn} do
      src = "xfer-src"
      dst = "xfer-dst"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(dst, "guest-22", %{"property_id" => "zzz-backup"}),
          open_op(src, "guest-22"),
          pay_op(src, 400),
          transfer_op(src, dst, 250)
        ]),
        &applied!/1
      )

      data = report(conn, "2026-10-10")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{"received_cents" => 400, "transferred_out_cents" => 250},
                 "closing_held_cents" => 150
               },
               %{
                 "property_id" => "zzz-backup",
                 "movements" => %{"transferred_in_cents" => 250},
                 "closing_held_cents" => 250
               }
             ] = data["cash"]

      # Transferred-in equals transferred-out across all properties.
      sums = data["cash"] |> Enum.map(& &1["movements"])

      assert Enum.sum(Enum.map(sums, & &1["transferred_in_cents"])) ==
               Enum.sum(Enum.map(sums, & &1["transferred_out_cents"]))
    end

    test "posts an op's effects on max(occurred_on, starts_on)", %{conn: conn} do
      group = "post-a"

      Enum.each(
        submit(conn, [
          open_op(group, "guest-22"),
          start_op("2026-10-10"),
          pay_op(group, 200, %{"occurred_on" => "2026-10-05"})
        ]),
        &applied!/1
      )

      day = report(conn, "2026-10-10")

      assert [
               %{
                 "movements" => %{"received_cents" => 200},
                 "closing_held_cents" => 200
               }
             ] = day["cash"]
    end

    test "refund, retention, and conversion settle held cash per property", %{conn: conn} do
      flex = "settle-flex"
      advance = "settle-adv"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(flex, "guest-22"),
          open_op(advance, "guest-22", %{"rate_plan" => "advance_purchase"}),
          pay_op(flex, 500),
          pay_op(advance, 500),
          cancel_op(flex),
          cancel_op(advance, %{"occurred_on" => "2026-12-05"})
        ]),
        &applied!/1
      )

      day26 = report(conn, "2026-11-26")

      assert [
               %{
                 "movements" => %{"refunded_cents" => 500},
                 "closing_held_cents" => 500
               }
             ] = day26["cash"]

      day5 = report(conn, "2026-12-05")

      assert [
               %{
                 "movements" => %{"retained_cents" => 500},
                 "closing_held_cents" => 0
               }
             ] = day5["cash"]

      assert %{"cash_refunded_cents" => 500, "cash_retained_cents" => 500} = ledger(conn)
    end

    test "conversion settles cash and issues credit liability the same day", %{conn: conn} do
      group = "conv-a"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          pay_op(group, 400),
          cancel_op(group, %{"refund_method" => "hotel_credit"})
        ]),
        &applied!/1
      )

      data = report(conn, "2026-11-26")

      assert [
               %{
                 "movements" => %{"converted_to_credit_cents" => 400},
                 "closing_held_cents" => 0
               }
             ] = data["cash"]

      credit = data["credit"]

      assert %{
               "opening_liability_cents" => 0,
               "movements" => %{"issued_cents" => 440},
               "closing_liability_cents" => 440
             } = credit
    end

    test "a durable retry does not report the movement twice", %{conn: conn} do
      group = "idem-a"

      applied!(submit_one(conn, start_op("2026-10-10")))
      applied!(submit_one(conn, open_op(group, "guest-22")))
      op = pay_op(group, 300)
      first = applied!(submit_one(conn, op))
      assert submit_one(conn, op) == first

      data = report(conn, "2026-10-10")

      assert [%{"movements" => %{"received_cents" => 300}, "closing_held_cents" => 300}] =
               data["cash"]
    end

    test "a rejected operation reports no movement", %{conn: conn} do
      group = "rej-a"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(group, "guest-22"),
          pay_op(group, 500),
          cancel_op(group)
        ]),
        &applied!/1
      )

      rejected = submit_one(conn, cancel_op(group))
      assert %{"status" => "rejected", "code" => "group_not_active"} = rejected

      data = report(conn, "2026-11-26")

      assert [%{"movements" => %{"refunded_cents" => 500}, "closing_held_cents" => 0}] =
               data["cash"]
    end

    test "a correction follows settled cash to the property where it settled", %{conn: conn} do
      src = "corr-src"
      dst = "corr-dst"
      pay = "pay-77"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(src, "guest-22"),
          open_op(dst, "guest-22", %{"property_id" => "zzz-backup"}),
          pay_op(src, 400, %{"operation_id" => pay}),
          transfer_op(src, dst, 250),
          cancel_op(dst),
          %{
            "operation_id" => next_id(),
            "type" => "charge_back_payment",
            "payment_operation_id" => pay,
            "occurred_on" => "2026-11-27"
          }
        ]),
        &applied!/1
      )

      data = report(conn, "2026-11-27")

      [landing, backup] = data["cash"]

      assert landing["property_id"] == "ams-canal"
      assert backup["property_id"] == "zzz-backup"

      # The refund reversal reclassifies at the destination property; the
      # still-held remainder charges back at its held property.
      assert %{
               "movements" => %{
                 "refunded_cents" => -250,
                 "charged_back_cents" => 250
               }
             } = backup

      assert %{"movements" => %{"charged_back_cents" => 150}} = landing

      day = report(conn, "2026-11-26")
      [_, backup_day] = day["cash"]
      assert %{"movements" => %{"refunded_cents" => 250}} = backup_day
    end
  end

  describe "credit reporting" do
    test "non-refundable settlement consumes applied credit", %{conn: conn} do
      source = "cons-src"

      # Build a credit lot (issued on 2026-11-26), then apply it to a
      # non-refundable group settled on 2026-12-05.
      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(source, "guest-22"),
          open_op("cons-dst", "guest-22", %{"rate_plan" => "advance_purchase"}),
          pay_op(source, 400),
          cancel_op(source, %{"refund_method" => "hotel_credit"}),
          credit_op("cons-dst", 440),
          cancel_op("cons-dst", %{"occurred_on" => "2026-12-05"})
        ]),
        &applied!/1
      )

      consumed_day = report(conn, "2026-12-05")
      credit = consumed_day["credit"]

      assert %{
               "opening_liability_cents" => 440,
               "movements" => %{"consumed_cents" => 440},
               "closing_liability_cents" => 0
             } = credit

      assert %{"credit_liability_cents" => 0} = ledger(conn)
    end

    test "applying credit to an active group moves no liability", %{conn: conn} do
      source = "pap-src"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(source, "guest-22"),
          open_op("pap-dst", "guest-22"),
          pay_op(source, 400),
          cancel_op(source, %{"refund_method" => "hotel_credit"}),
          credit_op("pap-dst", 300)
        ]),
        &applied!/1
      )

      data = report(conn, "2026-11-26")
      credit = data["credit"]

      assert %{
               "movements" => %{
                 "issued_cents" => 440,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 440
             } = credit
    end

    test "credit available through its expires_on date expires the following day", %{conn: conn} do
      source = "exp-src"

      Enum.each(
        submit(conn, [
          open_op(source, "guest-22"),
          pay_op(source, 400),
          cancel_op(source, %{"refund_method" => "hotel_credit"}),
          start_op("2026-10-10")
        ]),
        &applied!/1
      )

      # The lot was issued on 2026-11-26 and expires on 2027-11-26; the day
      # after, the report shows the expiry without any operation posting it.
      data = report(conn, "2027-11-27")
      credit = data["credit"]

      assert %{
               "opening_liability_cents" => 440,
               "movements" => %{"expired_cents" => 440},
               "closing_liability_cents" => 0
             } = credit

      day_before = report(conn, "2027-11-26")

      assert %{"movements" => %{"expired_cents" => 0}, "closing_liability_cents" => 440} =
               day_before["credit"]
    end

    test "chargeback revokes entitlement and reverses the conversion", %{conn: conn} do
      source = "rev-src"

      [_, _, _, settled, chargeback] =
        submit(conn, [
          start_op("2026-10-10"),
          open_op(source, "guest-22"),
          pay_op(source, 400, %{"operation_id" => "pay-1"}),
          cancel_op(source, %{"refund_method" => "hotel_credit"}),
          %{
            "operation_id" => next_id(),
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-1",
            "occurred_on" => "2026-11-27"
          }
        ])

      Enum.each([settled, chargeback], &applied!/1)

      data = report(conn, "2026-11-27")

      assert [
               %{
                 "movements" => %{
                   "converted_to_credit_cents" => -400,
                   "charged_back_cents" => 400
                 },
                 "closing_held_cents" => 0
               }
             ] = data["cash"]

      credit = data["credit"]

      assert %{
               "opening_liability_cents" => 440,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 440,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 0
             } = credit

      # The issuance itself posted on the settlement date.
      issue_day = report(conn, "2026-11-26")

      assert %{
               "movements" => %{"issued_cents" => 440, "revoked_cents" => 0},
               "closing_liability_cents" => 440
             } = issue_day["credit"]
    end

    test "restored credit absorbs the lot's unrecovered clawback", %{conn: conn} do
      source = "abs-src"
      holder = "abs-dst"

      Enum.each(
        submit(conn, [
          start_op("2026-10-10"),
          open_op(source, "guest-22"),
          open_op(holder, "guest-22"),
          pay_op(source, 400, %{"operation_id" => "pay-9"}),
          cancel_op(source, %{"refund_method" => "hotel_credit"}),
          credit_op(holder, 440),
          %{
            "operation_id" => next_id(),
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-9"
          },
          cancel_op(holder)
        ]),
        &applied!/1
      )

      # The chargeback finds nothing available (everything applied), so the
      # full entitlement becomes an unrecovered clawback; the refundable
      # settle of the holder restores the credit into that shortfall.
      data = report(conn, "2026-11-26")
      credit = data["credit"]

      assert %{
               "movements" => %{
                 "issued_cents" => 440,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 440
               },
               "closing_liability_cents" => 0
             } = credit

      assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0} = ledger(conn)
    end
  end
end
