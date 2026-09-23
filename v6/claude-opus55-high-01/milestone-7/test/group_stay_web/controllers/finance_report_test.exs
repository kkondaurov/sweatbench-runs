defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Repo

  # Groups are booked 2026-10-03 under flex-14 unless stated otherwise, arrive 2026-12-10, are
  # refundable until 2026-11-26, and need 9000 cents for room-a and 10_500 for room-b.

  @zero_cash %{
    "received_cents" => 0,
    "transferred_in_cents" => 0,
    "transferred_out_cents" => 0,
    "refunded_cents" => 0,
    "retained_cents" => 0,
    "converted_to_credit_cents" => 0,
    "reduced_cents" => 0,
    "charged_back_cents" => 0
  }

  @zero_credit %{
    "issued_cents" => 0,
    "expired_cents" => 0,
    "consumed_cents" => 0,
    "revoked_cents" => 0,
    "absorbed_cents" => 0
  }

  @no_late_adjustments %{"cash" => [], "credit" => @zero_credit}

  defp open(group_id, property_id, overrides \\ %{}) do
    assert %{"status" => "applied"} =
             submit_one(
               open_group_op(
                 Map.merge(
                   %{
                     "operation_id" => "open-#{group_id}",
                     "group_id" => group_id,
                     "property_id" => property_id
                   },
                   overrides
                 )
               )
             )
  end

  defp pay(operation_id, group_id, amount, occurred_on) do
    assert %{"status" => "applied"} =
             submit_one(
               payment_op(%{
                 "operation_id" => operation_id,
                 "group_id" => group_id,
                 "amount_cents" => amount,
                 "occurred_on" => occurred_on
               })
             )
  end

  defp apply_credit(group_id, amount, occurred_on) do
    assert %{"status" => "applied"} =
             submit_one(
               apply_credit_op(%{
                 "group_id" => group_id,
                 "amount_cents" => amount,
                 "occurred_on" => occurred_on
               })
             )
  end

  defp cancel(group_id, occurred_on, overrides \\ %{}) do
    assert %{"status" => "applied"} =
             submit_one(
               cancel_op(
                 Map.merge(%{"group_id" => group_id, "occurred_on" => occurred_on}, overrides)
               )
             )
  end

  # Issues guest-22 a 5500 cent lot, "cancel-17", from 5000 cents paid to group-src at ams-canal.
  # Issued on 2026-10-06, it expires on 2027-10-07.
  defp issue_credit do
    open("group-src", "ams-canal")
    pay("pay-src", "group-src", 5000, "2026-10-06")

    cancel("group-src", "2026-10-06", %{
      "operation_id" => "cancel-17",
      "refund_method" => "hotel_credit"
    })
  end

  defp start(starts_on) do
    result =
      submit_one(start_reporting_op(%{"operation_id" => "start", "starts_on" => starts_on}))

    assert result == %{"operation_id" => "start", "status" => "applied", "starts_on" => starts_on}
  end

  defp transfer(source, destination, amount, occurred_on) do
    assert %{"status" => "applied"} =
             submit_one(%{
               "operation_id" => unique_operation_id("op-transfer"),
               "type" => "transfer_deposit",
               "occurred_on" => occurred_on,
               "source_group_id" => source,
               "destination_group_id" => destination,
               "amount_cents" => amount
             })
  end

  defp cash(property_id, opening, movements, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => Map.merge(@zero_cash, movements),
      "closing_held_cents" => closing
    }
  end

  defp credit(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(@zero_credit, movements),
      "closing_liability_cents" => closing
    }
  end

  defp report(date), do: get_daily_report(date)

  defp error(date) do
    response = get_daily_report_response(date)
    {response.status, Jason.decode!(response.resp_body)}
  end

  # Checks every report from `from` through `to`: each balances, transfers net to zero across
  # properties, and each day opens where the previous day closed. Returns the reports.
  defp assert_consistent(from, to) do
    reports = for date <- Date.range(from, to), do: report(Date.to_iso8601(date))

    for report <- reports do
      for entry <- report["cash"] do
        m = entry["movements"]

        assert entry["closing_held_cents"] ==
                 entry["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                   m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                   m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
      end

      assert Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"])) ==
               Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))

      credit = report["credit"]
      m = credit["movements"]

      assert credit["closing_liability_cents"] ==
               credit["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
                 m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]
    end

    for [previous, next] <- Enum.chunk_every(reports, 2, 1, :discard) do
      assert next["credit"]["opening_liability_cents"] ==
               previous["credit"]["closing_liability_cents"]

      closing = Map.new(previous["cash"], &{&1["property_id"], &1["closing_held_cents"]})
      opening = Map.new(next["cash"], &{&1["property_id"], &1["opening_held_cents"]})
      assert Map.reject(closing, &(elem(&1, 1) == 0)) == Map.reject(opening, &(elem(&1, 1) == 0))
    end

    reports
  end

  # The closing position on `date` agrees with the current ledger read as of that date, once no
  # operation posts after it.
  defp assert_reconciles(date) do
    report = report(date)
    ledger = get_ledger(%{"on" => date})

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger["cash_held_cents"]

    assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]
  end

  defp postings, do: db_snapshot()["finance_postings"]

  describe "starting finance reporting" do
    test "applies once and returns exactly its identifier, status, and start date" do
      op = start_reporting_op(%{"operation_id" => "start-1", "starts_on" => "2026-10-05"})

      expected = %{
        "operation_id" => "start-1",
        "status" => "applied",
        "starts_on" => "2026-10-05"
      }

      assert submit_one(op) == expected
      assert submit_one(op) == expected
      assert get_operation("start-1") == expected

      assert submit_one(
               start_reporting_op(%{"operation_id" => "start-2", "starts_on" => "2026-10-05"})
             ) == %{
               "operation_id" => "start-2",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               submit_one(Map.put(op, "starts_on", "2026-10-01"))

      assert %{"date" => "2026-10-05"} = report("2026-10-05")
      assert error("2026-10-04") == {404, %{"error" => %{"code" => "report_not_available"}}}
    end

    test "rejects a missing or invalid start date without starting reporting" do
      for starts_on <- [
            nil,
            "2026-02-30",
            "2026-10-5",
            "tomorrow",
            "",
            20_261_005,
            ["2026-10-05"]
          ] do
        op = start_reporting_op(%{"starts_on" => starts_on})
        op = if starts_on, do: op, else: Map.delete(op, "starts_on")

        assert submit_one(op) == %{
                 "operation_id" => op["operation_id"],
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
      end

      assert db_snapshot()["finance_reporting"] == []
      assert error("2026-10-05") == {404, %{"error" => %{"code" => "report_not_available"}}}

      start("2026-10-05")
    end

    test "does not need an occurred_on date, but rejects an unusable one" do
      op = start_reporting_op() |> Map.delete("occurred_on")

      assert %{"status" => "rejected", "code" => "invalid_operation"} =
               submit_one(Map.put(op, "occurred_on", "someday"))

      assert %{"status" => "applied", "starts_on" => "2026-10-05"} =
               submit_one(Map.put(op, "operation_id", "start-without-date"))
    end

    test "ignores group revision fields" do
      open("group-81", "ams-canal")

      assert %{"status" => "applied"} =
               submit_one(
                 start_reporting_op(%{"group_id" => "group-81", "expected_revision" => 9})
               )

      assert get_group("group-81")["revision"] == 1
    end
  end

  describe "reading a report" do
    test "requires a valid date" do
      invalid = {422, %{"error" => %{"code" => "invalid_reporting_date"}}}

      assert error(nil) == invalid
      assert error("2026-13-01") == invalid

      start("2026-10-05")

      for date <- [nil, "2026-13-01", "2026-10-5", "yesterday", "", "2026-10-05T00:00:00Z"],
          do: assert(error(date) == invalid)

      conn = get(build_conn(), "/api/v1/finance/daily-report?date[]=2026-10-05")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "is not available before reporting starts or before the start date" do
      not_available = {404, %{"error" => %{"code" => "report_not_available"}}}
      assert error("2026-10-05") == not_available

      start("2026-10-05")

      assert error("2026-10-04") == not_available
      assert error("2025-01-01") == not_available
    end

    test "reports an empty position from the start date onward" do
      start("2026-10-05")

      for date <- ["2026-10-05", "2026-10-06", "2031-01-01"] do
        assert report(date) == %{
                 "date" => date,
                 "status" => "open",
                 "late_adjustments" => @no_late_adjustments,
                 "cash" => [],
                 "credit" => credit(0, %{}, 0)
               }
      end
    end
  end

  describe "the opening position" do
    test "is the state immediately before reporting starts, including operations dated later" do
      open("group-81", "ams-canal")
      pay("pay-81", "group-81", 5000, "2026-10-04")
      open("group-92", "ber-mitte")
      pay("pay-92", "group-92", 3000, "2026-10-09")
      open("group-77", "cph-harbour")
      issue_credit()

      start("2026-10-05")

      assert report("2026-10-05") == %{
               "date" => "2026-10-05",
               "status" => "open",
               "late_adjustments" => @no_late_adjustments,
               "cash" => [
                 cash("ams-canal", 5000, %{}, 5000),
                 cash("ber-mitte", 3000, %{}, 3000)
               ],
               "credit" => credit(5500, %{}, 5500)
             }

      # The payment dated after the start date is already part of the opening position.
      assert report("2026-10-09")["cash"] == [
               cash("ams-canal", 5000, %{}, 5000),
               cash("ber-mitte", 3000, %{}, 3000)
             ]

      assert_consistent(~D[2026-10-05], ~D[2026-10-12])
      assert_reconciles("2026-10-12")
    end

    test "in one batch, operations before the start open and operations after it move" do
      open("group-81", "ams-canal")

      results =
        submit([
          payment_op(%{"operation_id" => "pay-1", "amount_cents" => 1000}),
          start_reporting_op(%{"operation_id" => "start", "starts_on" => "2026-10-05"}),
          payment_op(%{"operation_id" => "pay-2", "amount_cents" => 2000}),
          payment_op(%{
            "operation_id" => "pay-3",
            "amount_cents" => 400,
            "occurred_on" => "2026-10-07"
          })
        ])

      assert Enum.map(results, & &1["status"]) == ~w(applied applied applied applied)

      # pay-2 occurred on 2026-10-04, before the start, so it posts on the start date.
      assert report("2026-10-05")["cash"] == [
               cash("ams-canal", 1000, %{"received_cents" => 2000}, 3000)
             ]

      assert report("2026-10-06")["cash"] == [cash("ams-canal", 3000, %{}, 3000)]

      assert report("2026-10-07")["cash"] == [
               cash("ams-canal", 3000, %{"received_cents" => 400}, 3400)
             ]
    end

    test "includes applied credit and lots that expire on the start date" do
      issue_credit()

      open("group-81", "ams-canal", %{
        "occurred_on" => "2027-01-05",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      })

      apply_credit("group-81", 3000, "2027-01-05")

      start("2027-10-07")

      assert report("2027-10-07")["credit"] ==
               credit(5500, %{"expired_cents" => 2500}, 3000)

      assert_reconciles("2027-10-07")
    end

    test "excludes lots that expired before the start date" do
      issue_credit()
      start("2027-10-08")

      assert report("2027-10-08")["credit"] == credit(0, %{}, 0)
    end
  end

  describe "posting dates" do
    test "post each operation on the later of its occurred_on and the start date" do
      open("group-81", "ams-canal")
      start("2026-10-10")

      pay("pay-early", "group-81", 1000, "2026-10-04")
      pay("pay-late", "group-81", 500, "2026-10-12")

      assert report("2026-10-10")["cash"] == [
               cash("ams-canal", 0, %{"received_cents" => 1000}, 1000)
             ]

      assert report("2026-10-11")["cash"] == [cash("ams-canal", 1000, %{}, 1000)]

      assert report("2026-10-12")["cash"] == [
               cash("ams-canal", 1000, %{"received_cents" => 500}, 1500)
             ]
    end

    test "use one date for every effect of an operation" do
      open("group-src", "ams-canal")
      pay("pay-src", "group-src", 5000, "2026-10-04")
      start("2026-10-10")

      cancel("group-src", "2026-10-06", %{"refund_method" => "hotel_credit"})

      assert report("2026-10-10") == %{
               "date" => "2026-10-10",
               "status" => "open",
               "late_adjustments" => @no_late_adjustments,
               "cash" => [
                 cash("ams-canal", 5000, %{"converted_to_credit_cents" => 5000}, 0)
               ],
               "credit" => credit(0, %{"issued_cents" => 5500}, 5500)
             }

      # The lot still expires 366 days after the cancellation date.
      assert report("2027-10-07")["credit"] == credit(5500, %{"expired_cents" => 5500}, 0)
      assert_reconciles("2027-10-07")
    end

    test "let a later submission change an earlier open report" do
      open("group-81", "ams-canal")
      start("2026-10-05")
      pay("pay-1", "group-81", 1000, "2026-10-08")

      assert report("2026-10-08")["cash"] == [
               cash("ams-canal", 0, %{"received_cents" => 1000}, 1000)
             ]

      pay("pay-2", "group-81", 500, "2026-10-06")

      assert report("2026-10-06")["cash"] == [
               cash("ams-canal", 0, %{"received_cents" => 500}, 500)
             ]

      assert report("2026-10-08")["cash"] == [
               cash("ams-canal", 500, %{"received_cents" => 1000}, 1500)
             ]

      assert_consistent(~D[2026-10-05], ~D[2026-10-09])
    end
  end

  describe "cash movements" do
    setup do
      start("2026-10-05")
      open("group-81", "ams-canal")
      open("group-92", "ber-mitte")
      :ok
    end

    test "follow cash through transfers, settlement, and corrections" do
      pay("pay-81", "group-81", 6000, "2026-10-06")
      pay("pay-92", "group-92", 4000, "2026-10-06")
      transfer("group-81", "group-92", 2500, "2026-10-07")

      # The transferred cash is pay-81's most recent allocation, now held by ber-mitte.
      assert %{"status" => "applied"} =
               submit_one(
                 reduce_op(%{
                   "payment_operation_id" => "pay-81",
                   "amount_cents" => 1000,
                   "occurred_on" => "2026-10-08"
                 })
               )

      assert %{"refunded_cents" => 5500} = cancel("group-92", "2026-10-09")

      assert %{"status" => "applied", "charged_back_cents" => 5000} =
               submit_one(
                 charge_back_op(%{
                   "payment_operation_id" => "pay-81",
                   "occurred_on" => "2026-10-10"
                 })
               )

      pay("pay-81b", "group-81", 2000, "2026-10-11")
      assert %{"retained_cents" => 2000} = cancel("group-81", "2026-11-30")

      assert report("2026-10-06")["cash"] == [
               cash("ams-canal", 0, %{"received_cents" => 6000}, 6000),
               cash("ber-mitte", 0, %{"received_cents" => 4000}, 4000)
             ]

      assert report("2026-10-07")["cash"] == [
               cash("ams-canal", 6000, %{"transferred_out_cents" => 2500}, 3500),
               cash("ber-mitte", 4000, %{"transferred_in_cents" => 2500}, 6500)
             ]

      assert report("2026-10-08")["cash"] == [
               cash("ams-canal", 3500, %{}, 3500),
               cash("ber-mitte", 6500, %{"reduced_cents" => 1000}, 5500)
             ]

      assert report("2026-10-09")["cash"] == [
               cash("ams-canal", 3500, %{}, 3500),
               cash("ber-mitte", 5500, %{"refunded_cents" => 5500}, 0)
             ]

      # The refunded part of pay-81 was settled by ber-mitte and is reclassified there.
      assert report("2026-10-10")["cash"] == [
               cash("ams-canal", 3500, %{"charged_back_cents" => 3500}, 0),
               cash("ber-mitte", 0, %{"refunded_cents" => -1500, "charged_back_cents" => 1500}, 0)
             ]

      assert report("2026-10-11")["cash"] == [
               cash("ams-canal", 0, %{"received_cents" => 2000}, 2000)
             ]

      assert report("2026-11-30")["cash"] == [
               cash("ams-canal", 2000, %{"retained_cents" => 2000}, 0)
             ]

      assert report("2026-12-01")["cash"] == []

      reports = assert_consistent(~D[2026-10-05], ~D[2026-12-01])
      assert_reconciles("2026-12-01")

      # Net movements since the start agree with the ledger's cumulative totals.
      ledger = get_ledger(%{"on" => "2026-12-01"})

      for {movement, total} <- [
            {"received_cents", 12_000},
            {"refunded_cents", ledger["cash_refunded_cents"]},
            {"retained_cents", ledger["cash_retained_cents"]},
            {"reduced_cents", ledger["cash_reduced_cents"]},
            {"charged_back_cents", ledger["cash_charged_back_cents"]}
          ] do
        assert reports
               |> Enum.flat_map(& &1["cash"])
               |> Enum.map(& &1["movements"][movement])
               |> Enum.sum() == total
      end
    end

    test "report a transfer within one property as both in and out" do
      open("group-83", "ams-canal")
      pay("pay-81", "group-81", 3000, "2026-10-06")
      transfer("group-81", "group-83", 1000, "2026-10-07")

      assert report("2026-10-07")["cash"] == [
               cash(
                 "ams-canal",
                 3000,
                 %{"transferred_in_cents" => 1000, "transferred_out_cents" => 1000},
                 3000
               )
             ]
    end

    test "report cancelled rooms under the group's property" do
      pay("pay-92", "group-92", 12_000, "2026-10-06")

      assert %{"status" => "applied", "refunded_cents" => 9000} =
               submit_one(
                 cancel_rooms_op(%{
                   "group_id" => "group-92",
                   "occurred_on" => "2026-10-07"
                 })
               )

      assert report("2026-10-07")["cash"] == [
               cash("ber-mitte", 12_000, %{"refunded_cents" => 9000}, 3000)
             ]
    end

    test "report the reversal of converted cash where it was converted" do
      pay("pay-81", "group-81", 5000, "2026-10-06")
      cancel("group-81", "2026-10-07", %{"refund_method" => "hotel_credit"})

      submit_one(
        charge_back_op(%{"payment_operation_id" => "pay-81", "occurred_on" => "2026-10-08"})
      )

      assert report("2026-10-08") == %{
               "date" => "2026-10-08",
               "status" => "open",
               "late_adjustments" => @no_late_adjustments,
               "cash" => [
                 cash(
                   "ams-canal",
                   0,
                   %{"converted_to_credit_cents" => -5000, "charged_back_cents" => 5000},
                   0
                 )
               ],
               "credit" => credit(5500, %{"revoked_cents" => 5500}, 0)
             }
    end
  end

  describe "credit movements" do
    setup do
      start("2026-10-05")
      :ok
    end

    test "report issue, consumption, and expiry, but not application or restoration" do
      issue_credit()

      open("group-81", "ams-canal")
      apply_credit("group-81", 3000, "2026-10-07")

      open("group-adv", "ams-canal", %{"rate_plan" => "advance_purchase"})
      apply_credit("group-adv", 1000, "2026-10-07")

      cancel("group-adv", "2026-10-08")
      cancel("group-81", "2026-10-09")

      assert report("2026-10-06") == %{
               "date" => "2026-10-06",
               "status" => "open",
               "late_adjustments" => @no_late_adjustments,
               "cash" => [
                 cash(
                   "ams-canal",
                   0,
                   %{"received_cents" => 5000, "converted_to_credit_cents" => 5000},
                   0
                 )
               ],
               "credit" => credit(0, %{"issued_cents" => 5500}, 5500)
             }

      assert report("2026-10-07")["credit"] == credit(5500, %{}, 5500)
      assert report("2026-10-08")["credit"] == credit(5500, %{"consumed_cents" => 1000}, 4500)
      assert report("2026-10-09")["credit"] == credit(4500, %{}, 4500)

      # Unused credit is usable through 2027-10-06 and expires without any operation.
      assert report("2027-10-06") == %{
               "date" => "2027-10-06",
               "status" => "open",
               "late_adjustments" => @no_late_adjustments,
               "cash" => [],
               "credit" => credit(4500, %{}, 4500)
             }

      assert report("2027-10-07")["credit"] == credit(4500, %{"expired_cents" => 4500}, 0)
      assert report("2027-10-08")["credit"] == credit(0, %{}, 0)

      assert_consistent(~D[2026-10-05], ~D[2026-10-12])
      assert_consistent(~D[2027-10-05], ~D[2027-10-09])

      for date <- ~w(2026-10-09 2027-10-06 2027-10-07), do: assert_reconciles(date)
    end

    test "report revocation by chargeback and absorption of returning credit" do
      issue_credit()
      open("group-81", "ams-canal")
      apply_credit("group-81", 5000, "2026-10-07")

      submit_one(
        charge_back_op(%{"payment_operation_id" => "pay-src", "occurred_on" => "2026-10-08"})
      )

      assert get_ledger(%{"on" => "2026-10-08"})["credit_shortfall_cents"] == 5000

      assert report("2026-10-08") == %{
               "date" => "2026-10-08",
               "status" => "open",
               "late_adjustments" => @no_late_adjustments,
               "cash" => [
                 cash(
                   "ams-canal",
                   0,
                   %{"converted_to_credit_cents" => -5000, "charged_back_cents" => 5000},
                   0
                 )
               ],
               "credit" => credit(5500, %{"revoked_cents" => 500}, 5000)
             }

      cancel("group-81", "2026-10-09")

      assert report("2026-10-09")["credit"] == credit(5000, %{"absorbed_cents" => 5000}, 0)
      assert report("2027-10-07")["credit"] == credit(0, %{}, 0)

      for date <- ~w(2026-10-09 2027-10-07), do: assert_reconciles(date)
    end

    test "report credit restored after its lot expired as expired on the cancellation date" do
      issue_credit()

      open("group-81", "ams-canal", %{
        "occurred_on" => "2026-10-07",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      })

      apply_credit("group-81", 3000, "2026-10-07")

      assert report("2027-10-07")["credit"] == credit(5500, %{"expired_cents" => 2500}, 3000)
      assert_reconciles("2027-10-07")

      cancel("group-81", "2027-11-01")

      assert report("2027-11-01")["credit"] == credit(3000, %{"expired_cents" => 3000}, 0)
      assert_consistent(~D[2027-10-06], ~D[2027-11-02])

      assert_reconciles("2027-11-01")
    end

    test "do not change with transfers of applied credit" do
      issue_credit()
      open("group-81", "ams-canal")
      open("group-92", "ber-mitte")
      apply_credit("group-81", 2000, "2026-10-07")
      transfer("group-81", "group-92", 2000, "2026-10-08")

      assert report("2026-10-08") == %{
               "date" => "2026-10-08",
               "status" => "open",
               "late_adjustments" => @no_late_adjustments,
               "cash" => [],
               "credit" => credit(5500, %{}, 5500)
             }
    end
  end

  describe "credit posted on or after its lot's expiry" do
    setup do
      issue_credit()

      open("group-81", "ams-canal", %{
        "occurred_on" => "2027-01-05",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      })

      :ok
    end

    test "offsets the expiry when credit usable when applied posts on the expiry date" do
      start("2027-10-07")
      apply_credit("group-81", 3000, "2027-10-06")

      assert report("2027-10-07")["credit"] == credit(5500, %{"expired_cents" => 2500}, 3000)
      assert_reconciles("2027-10-07")
    end

    test "reports credit applied from a lot that expired before the posting date" do
      start("2027-10-10")
      apply_credit("group-81", 3000, "2027-10-06")

      assert report("2027-10-10")["credit"] == credit(0, %{"expired_cents" => -3000}, 3000)
      assert_reconciles("2027-10-10")

      # Restored after the lot's expiry date, it expires again.
      cancel("group-81", "2027-10-06")

      assert report("2027-10-10")["credit"] == credit(0, %{}, 0)
      assert_reconciles("2027-10-10")
    end

    test "does not revoke credit that has already expired" do
      start("2027-10-10")

      submit_one(
        charge_back_op(%{"payment_operation_id" => "pay-src", "occurred_on" => "2027-10-10"})
      )

      assert report("2027-10-10")["credit"] == credit(0, %{}, 0)
      assert_reconciles("2027-10-10")
    end
  end

  describe "report durability" do
    setup do
      open("group-81", "ams-canal")
      start("2026-10-05")
      :ok
    end

    test "rejected operations post nothing" do
      before = db_snapshot()

      for op <- [
            payment_op(%{"amount_cents" => 20_000}),
            payment_op(%{"expected_revision" => 5}),
            apply_credit_op(),
            cancel_op(%{"refund_method" => "hotel_credit", "occurred_on" => "2026-12-01"}),
            reduce_op(%{"payment_operation_id" => "nothing"})
          ] do
        assert %{"status" => "rejected"} = submit_one(op)
      end

      assert db_snapshot() == before
    end

    test "retries and rejected later operations keep movements exactly once" do
      op = payment_op(%{"operation_id" => "pay-1", "amount_cents" => 1000})

      assert [%{"status" => "applied"}, %{"status" => "rejected"}] =
               submit([op, payment_op(%{"amount_cents" => 50_000})])

      assert [%{"status" => "applied"}] = submit([op])
      assert length(postings()) == 1

      assert report("2026-10-05")["cash"] == [
               cash("ams-canal", 0, %{"received_cents" => 1000}, 1000)
             ]
    end

    test "reading reports never changes them or any state" do
      issue_credit()
      apply_credit("group-81", 1000, "2026-10-07")

      dates = ~w(2027-10-08 2026-10-05 2027-10-07 2026-10-07 2026-10-06)
      before = db_snapshot()
      first = Enum.map(dates, &report/1)

      assert Enum.map(Enum.reverse(dates), &report/1) == Enum.reverse(first)
      assert Enum.map(dates, &report/1) == first
      assert db_snapshot() == before
    end

    test "equivalent batches and sequential submissions produce equivalent reports" do
      operations = [
        payment_op(%{"operation_id" => "pay-1", "amount_cents" => 5000}),
        cancel_op(%{
          "operation_id" => "cancel-1",
          "refund_method" => "hotel_credit",
          "occurred_on" => "2026-10-07"
        }),
        open_group_op(%{
          "operation_id" => "open-92",
          "group_id" => "group-92",
          "property_id" => "ber-mitte",
          "occurred_on" => "2026-10-06"
        }),
        apply_credit_op(%{
          "group_id" => "group-92",
          "amount_cents" => 2000,
          "occurred_on" => "2026-10-08"
        }),
        payment_op(%{
          "group_id" => "group-92",
          "amount_cents" => 3000,
          "occurred_on" => "2026-10-08"
        })
      ]

      dates = ~w(2026-10-05 2026-10-06 2026-10-07 2026-10-08 2027-10-08)

      {:error, sequential} =
        Repo.transaction(fn ->
          for op <- operations, do: assert(%{"status" => "applied"} = submit_one(op))
          Repo.rollback(Enum.map(dates, &report/1))
        end)

      assert Enum.all?(submit(operations), &(&1["status"] == "applied"))
      assert Enum.map(dates, &report/1) == sequential
    end
  end
end
