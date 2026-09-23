defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  # Groups are booked 2026-10-03 under flex-14 unless stated otherwise, arrive 2026-12-10, are
  # refundable until 2026-11-26, and need 19_500 cents in total. Reporting starts on 2026-10-05.

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

  @invalid_period %{"status" => "rejected", "code" => "invalid_period"}

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

  defp cancel(group_id, occurred_on, overrides \\ %{}) do
    assert %{"status" => "applied"} =
             submit_one(
               cancel_op(
                 Map.merge(%{"group_id" => group_id, "occurred_on" => occurred_on}, overrides)
               )
             )
  end

  defp charge_back(payment_operation_id, occurred_on) do
    assert %{"status" => "applied"} =
             submit_one(
               charge_back_op(%{
                 "payment_operation_id" => payment_operation_id,
                 "occurred_on" => occurred_on
               })
             )
  end

  defp start(starts_on) do
    assert %{"status" => "applied"} =
             submit_one(
               start_reporting_op(%{"operation_id" => "start", "starts_on" => starts_on})
             )
  end

  defp close(period_end_on, operation_id \\ nil) do
    operation_id = operation_id || "close-#{period_end_on}"

    result =
      submit_one(
        close_period_op(%{"operation_id" => operation_id, "period_end_on" => period_end_on})
      )

    assert result == %{
             "operation_id" => operation_id,
             "status" => "applied",
             "period_end_on" => period_end_on
           }
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

  defp late(cash, credit \\ %{}) do
    %{
      "cash" =>
        for(
          {property_id, movements} <- cash,
          do: %{"property_id" => property_id, "movements" => Map.merge(@zero_cash, movements)}
        ),
      "credit" => Map.merge(@zero_credit, credit)
    }
  end

  defp report(date), do: get_daily_report(date)

  # The report's `data` exactly as the API returns it.
  defp raw_report(date) do
    response = get_daily_report_response(date)
    assert response.status == 200
    ~r/\A\{"data":(.*)\}\z/s |> Regex.run(response.resp_body) |> List.last()
  end

  defp raw_reports(from, to),
    do: for(date <- Date.range(from, to), into: %{}, do: {date, raw_report(to_string(date))})

  # Checks every report from `from` through `to`: each balances with its ordinary and late
  # movements, transfers net to zero, and each day opens where the previous day closed.
  defp assert_consistent(from, to) do
    reports = for date <- Date.range(from, to), do: report(Date.to_iso8601(date))

    for report <- reports do
      late_cash = Map.new(report["late_adjustments"]["cash"], &{&1["property_id"], &1})

      for entry <- report["cash"] do
        late = get_in(late_cash, [entry["property_id"], "movements"]) || @zero_cash
        m = Map.new(entry["movements"], fn {k, v} -> {k, v + late[k]} end)

        assert entry["closing_held_cents"] ==
                 entry["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                   m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                   m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
      end

      # A property with late adjustments has moved, so it has an entry of its own.
      properties = Enum.map(report["cash"], & &1["property_id"])
      assert Enum.all?(Map.keys(late_cash), &(&1 in properties))

      credit = report["credit"]
      late = report["late_adjustments"]["credit"]
      m = Map.new(credit["movements"], fn {k, v} -> {k, v + late[k]} end)

      assert credit["closing_liability_cents"] ==
               credit["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
                 m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

      all_cash =
        Enum.flat_map(report["cash"] ++ report["late_adjustments"]["cash"], &[&1["movements"]])

      assert Enum.sum(Enum.map(all_cash, & &1["transferred_in_cents"])) ==
               Enum.sum(Enum.map(all_cash, & &1["transferred_out_cents"]))
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

  defp assert_reconciles(date) do
    report = report(date)
    ledger = get_ledger(%{"on" => date})

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger["cash_held_cents"]

    assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]
  end

  describe "closing a period" do
    test "applies with exactly its identifier, status, and cutoff, and replays its result" do
      start("2026-10-05")
      op = close_period_op(%{"operation_id" => "close-1", "period_end_on" => "2026-10-09"})

      expected = %{
        "operation_id" => "close-1",
        "status" => "applied",
        "period_end_on" => "2026-10-09"
      }

      assert submit_one(op) == expected
      assert submit_one(op) == expected
      assert get_operation("close-1") == expected

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               submit_one(Map.put(op, "period_end_on", "2026-10-12"))

      assert length(db_snapshot()["finance_period_closes"]) == 1
    end

    test "requires later cutoffs from different operations" do
      start("2026-10-05")
      close("2026-10-09")

      before = db_snapshot()

      for period_end_on <- ~w(2026-10-09 2026-10-08 2026-10-05) do
        op = close_period_op(%{"period_end_on" => period_end_on})
        assert submit_one(op) == Map.put(@invalid_period, "operation_id", op["operation_id"])
      end

      assert db_snapshot() == before
      assert report("2026-10-10")["status"] == "open"

      close("2026-10-10")
      assert report("2026-10-10")["status"] == "closed"

      # A retry of an earlier close still returns its stored result.
      close("2026-10-09")
      assert length(db_snapshot()["finance_period_closes"]) == 2
    end

    test "is rejected before reporting starts or before its start date" do
      assert Map.delete(
               submit_one(close_period_op(%{"period_end_on" => "2026-10-09"})),
               "operation_id"
             ) ==
               @invalid_period

      start("2026-10-05")

      assert Map.delete(
               submit_one(close_period_op(%{"period_end_on" => "2026-10-04"})),
               "operation_id"
             ) ==
               @invalid_period

      assert db_snapshot()["finance_period_closes"] == []

      # A close through the start date itself applies.
      close("2026-10-05")
      assert report("2026-10-05")["status"] == "closed"
    end

    test "rejects a missing or invalid cutoff" do
      start("2026-10-05")

      for period_end_on <- [
            nil,
            "2026-02-30",
            "2026-10-9",
            "today",
            "",
            20_261_009,
            ["2026-10-09"]
          ] do
        op = close_period_op(%{"period_end_on" => period_end_on})
        op = if period_end_on, do: op, else: Map.delete(op, "period_end_on")
        assert submit_one(op) == Map.put(@invalid_period, "operation_id", op["operation_id"])
      end

      # Closing the last calendar date would leave no open day to post on.
      op = close_period_op(%{"period_end_on" => "9999-12-31"})
      assert submit_one(op) == Map.put(@invalid_period, "operation_id", op["operation_id"])

      assert db_snapshot()["finance_period_closes"] == []
    end

    test "does not need an occurred_on date and ignores group revision fields" do
      open("group-81", "ams-canal")
      start("2026-10-05")

      assert %{"status" => "rejected", "code" => "invalid_operation"} =
               submit_one(close_period_op(%{"occurred_on" => "someday"}))

      op =
        close_period_op(%{"group_id" => "group-81", "expected_revision" => 9})
        |> Map.delete("occurred_on")

      assert %{"status" => "applied", "period_end_on" => "2026-10-09"} = submit_one(op)
      assert get_group("group-81")["revision"] == 1
    end

    test "marks reports through the cutoff closed and later reports open" do
      start("2026-10-05")
      assert report("2026-10-05")["status"] == "open"

      close("2026-10-09")

      for date <- ~w(2026-10-05 2026-10-09), do: assert(report(date)["status"] == "closed")
      for date <- ~w(2026-10-10 2027-01-01), do: assert(report(date)["status"] == "open")

      close("2026-10-20")

      for date <- ~w(2026-10-09 2026-10-10 2026-10-20),
          do: assert(report(date)["status"] == "closed")

      assert report("2026-10-21")["status"] == "open"
    end
  end

  describe "posting after a close" do
    setup do
      open("group-81", "ams-canal")
      start("2026-10-05")
      pay("pay-1", "group-81", 1000, "2026-10-06")
      :ok
    end

    test "moves an operation dated in the closed period to the first open day" do
      close("2026-10-09")
      closed = raw_reports(~D[2026-10-05], ~D[2026-10-09])

      pay("pay-2", "group-81", 500, "2026-10-07")

      assert raw_reports(~D[2026-10-05], ~D[2026-10-09]) == closed

      assert report("2026-10-10") == %{
               "date" => "2026-10-10",
               "status" => "open",
               "cash" => [cash("ams-canal", 1000, %{}, 1500)],
               "credit" => credit(0, %{}, 0),
               "late_adjustments" => late([{"ams-canal", %{"received_cents" => 500}}])
             }

      assert report("2026-10-11")["cash"] == [cash("ams-canal", 1500, %{}, 1500)]
      assert report("2026-10-11")["late_adjustments"] == late([])
      assert_consistent(~D[2026-10-05], ~D[2026-10-12])
      assert_reconciles("2026-10-12")
    end

    test "keeps the date of an operation already in the open period" do
      close("2026-10-09")

      pay("pay-2", "group-81", 500, "2026-10-10")
      pay("pay-3", "group-81", 300, "2026-10-12")

      assert report("2026-10-10")["cash"] == [
               cash("ams-canal", 1000, %{"received_cents" => 500}, 1500)
             ]

      assert report("2026-10-12")["cash"] == [
               cash("ams-canal", 1500, %{"received_cents" => 300}, 1800)
             ]

      for date <- ~w(2026-10-10 2026-10-12),
          do: assert(report(date)["late_adjustments"] == late([]))
    end

    test "moves an operation dated before the start date past the close" do
      close("2026-10-09")
      pay("pay-2", "group-81", 500, "2026-10-01")

      # Without the close it would post on the start date.
      assert report("2026-10-05")["cash"] == []

      assert report("2026-10-10")["late_adjustments"] ==
               late([{"ams-canal", %{"received_cents" => 500}}])
    end

    test "never moves a posting again after a later close" do
      close("2026-10-09")
      pay("pay-late", "group-81", 500, "2026-10-07")
      pay("pay-open", "group-81", 300, "2026-10-12")

      tenth = report("2026-10-10")
      twelfth = report("2026-10-12")

      close("2026-10-15")

      assert report("2026-10-10") == %{tenth | "status" => "closed"}
      assert report("2026-10-12") == %{twelfth | "status" => "closed"}

      pay("pay-later", "group-81", 200, "2026-10-12")

      assert report("2026-10-16")["late_adjustments"] ==
               late([{"ams-canal", %{"received_cents" => 200}}])

      assert report("2026-10-12") == %{twelfth | "status" => "closed"}
      assert_consistent(~D[2026-10-05], ~D[2026-10-17])
      assert_reconciles("2026-10-17")
    end

    test "sees operations earlier in the same batch" do
      results =
        submit([
          payment_op(%{
            "operation_id" => "pay-before",
            "amount_cents" => 500,
            "occurred_on" => "2026-10-08"
          }),
          close_period_op(%{"operation_id" => "close", "period_end_on" => "2026-10-09"}),
          payment_op(%{
            "operation_id" => "pay-after",
            "amount_cents" => 200,
            "occurred_on" => "2026-10-08"
          }),
          close_period_op(%{"operation_id" => "close-again", "period_end_on" => "2026-10-09"})
        ])

      assert Enum.map(results, &(&1["code"] || &1["status"])) ==
               ~w(applied applied applied invalid_period)

      # The payment just before the close posts into the period being closed.
      assert report("2026-10-08") == %{
               "date" => "2026-10-08",
               "status" => "closed",
               "cash" => [cash("ams-canal", 1000, %{"received_cents" => 500}, 1500)],
               "credit" => credit(0, %{}, 0),
               "late_adjustments" => late([])
             }

      assert report("2026-10-10")["late_adjustments"] ==
               late([{"ams-canal", %{"received_cents" => 200}}])

      assert_consistent(~D[2026-10-05], ~D[2026-10-11])
    end

    test "leaves current-state views and stored results with their existing meanings" do
      close("2026-10-09")

      result =
        submit_one(
          payment_op(%{
            "operation_id" => "pay-2",
            "amount_cents" => 500,
            "occurred_on" => "2026-10-07"
          })
        )

      assert result == %{
               "operation_id" => "pay-2",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 500,
               "outstanding_deposit_cents" => 18_000,
               "revision" => 3
             }

      assert get_operation("pay-2") == result
      assert get_group("group-81")["deposit_paid_cents"] == 1500
      assert get_ledger(%{"on" => "2026-10-07"})["cash_held_cents"] == 1500
      assert %{"payment_operation_id" => "pay-2"} = get_payment("pay-2")
    end

    test "rejected operations post nothing" do
      close("2026-10-09")
      before = db_snapshot()

      for op <- [
            payment_op(%{"amount_cents" => 50_000, "occurred_on" => "2026-10-07"}),
            payment_op(%{"expected_revision" => 9, "occurred_on" => "2026-10-07"}),
            reduce_op(%{"payment_operation_id" => "nothing", "occurred_on" => "2026-10-07"})
          ] do
        assert %{"status" => "rejected"} = submit_one(op)
      end

      assert db_snapshot() == before
      assert report("2026-10-10")["late_adjustments"] == late([])
    end
  end

  describe "late adjustments" do
    setup do
      open("group-81", "ams-canal")
      open("group-92", "ber-mitte")
      start("2026-10-05")
      :ok
    end

    test "keep signed classifications whose net balance effect is zero" do
      pay("pay-81", "group-81", 5000, "2026-10-06")
      assert %{"refunded_cents" => 5000} = cancel("group-81", "2026-10-07")
      close("2026-10-09")

      charge_back("pay-81", "2026-10-08")

      assert report("2026-10-10") == %{
               "date" => "2026-10-10",
               "status" => "open",
               "cash" => [cash("ams-canal", 0, %{}, 0)],
               "credit" => credit(0, %{}, 0),
               "late_adjustments" =>
                 late([{"ams-canal", %{"refunded_cents" => -5000, "charged_back_cents" => 5000}}])
             }

      assert_consistent(~D[2026-10-05], ~D[2026-10-11])
    end

    test "are ordered by property and report credit, alongside ordinary movements" do
      pay("pay-81", "group-81", 5000, "2026-10-06")
      pay("pay-92", "group-92", 3000, "2026-10-06")
      close("2026-10-09")

      # Ordinary movements on the first open day.
      pay("pay-92b", "group-92", 700, "2026-10-10")

      # Late: a transfer between properties and a conversion to credit.
      assert %{"status" => "applied"} =
               submit_one(%{
                 "operation_id" => "transfer-1",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-08",
                 "source_group_id" => "group-92",
                 "destination_group_id" => "group-81",
                 "amount_cents" => 1000
               })

      cancel("group-81", "2026-10-08", %{"refund_method" => "hotel_credit"})

      assert report("2026-10-10") == %{
               "date" => "2026-10-10",
               "status" => "open",
               "cash" => [
                 cash("ams-canal", 5000, %{}, 0),
                 cash("ber-mitte", 3000, %{"received_cents" => 700}, 2700)
               ],
               "credit" => credit(0, %{}, 6600),
               "late_adjustments" =>
                 late(
                   [
                     {"ams-canal",
                      %{"transferred_in_cents" => 1000, "converted_to_credit_cents" => 6000}},
                     {"ber-mitte", %{"transferred_out_cents" => 1000}}
                   ],
                   %{"issued_cents" => 6600}
                 )
             }

      # The lot still expires 366 days after the cancellation date, as an ordinary movement.
      assert report("2027-10-09")["credit"] == credit(6600, %{"expired_cents" => 6600}, 0)
      assert report("2027-10-09")["late_adjustments"] == late([])

      # Revoking the converted payment after a further close is again late.
      close("2026-10-31")
      charge_back("pay-81", "2026-10-20")

      assert report("2026-11-01")["late_adjustments"] ==
               late(
                 [
                   {"ams-canal",
                    %{"converted_to_credit_cents" => -5000, "charged_back_cents" => 5000}}
                 ],
                 %{"revoked_cents" => 5500}
               )

      assert_consistent(~D[2026-10-05], ~D[2026-11-02])
      assert_reconciles("2026-11-02")
    end

    test "report credit applied from a lot that expired in the closed period" do
      open("group-src", "ams-canal")
      pay("pay-src", "group-src", 5000, "2026-10-06")
      cancel("group-src", "2026-10-06", %{"refund_method" => "hotel_credit"})

      open("group-83", "ams-canal", %{
        "occurred_on" => "2027-01-05",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      })

      close("2027-10-09")
      closed = raw_reports(~D[2027-10-05], ~D[2027-10-09])
      assert report("2027-10-07")["credit"] == credit(5500, %{"expired_cents" => 5500}, 0)

      # Usable when applied, but posted after its lot's expiry.
      assert %{"status" => "applied"} =
               submit_one(
                 apply_credit_op(%{
                   "group_id" => "group-83",
                   "amount_cents" => 3000,
                   "occurred_on" => "2027-10-05"
                 })
               )

      assert raw_reports(~D[2027-10-05], ~D[2027-10-09]) == closed

      assert report("2027-10-10")["credit"] == credit(0, %{}, 3000)

      assert report("2027-10-10")["late_adjustments"] ==
               late([], %{"expired_cents" => -3000})

      assert_consistent(~D[2027-10-05], ~D[2027-10-11])
      assert_reconciles("2027-10-10")
    end
  end

  describe "closed reports" do
    test "stay byte-for-byte stable across later operations and closes" do
      open("group-81", "ams-canal")
      open("group-92", "ber-mitte")
      open("group-src", "cph-harbour")
      start("2026-10-05")

      pay("pay-81", "group-81", 6000, "2026-10-06")
      pay("pay-92", "group-92", 4000, "2026-10-06")
      pay("pay-src", "group-src", 5000, "2026-10-06")
      cancel("group-src", "2026-10-06", %{"refund_method" => "hotel_credit"})

      assert %{"status" => "applied"} =
               submit_one(
                 apply_credit_op(%{
                   "group_id" => "group-81",
                   "amount_cents" => 2000,
                   "occurred_on" => "2026-10-07"
                 })
               )

      close("2026-10-09")
      closed = raw_reports(~D[2026-10-05], ~D[2026-10-09])

      # Old-dated operations of every kind.
      assert Enum.all?(
               submit([
                 payment_op(%{
                   "group_id" => "group-81",
                   "amount_cents" => 900,
                   "occurred_on" => "2026-10-05"
                 }),
                 %{
                   "operation_id" => "transfer-1",
                   "type" => "transfer_deposit",
                   "occurred_on" => "2026-10-06",
                   "source_group_id" => "group-81",
                   "destination_group_id" => "group-92",
                   "amount_cents" => 1500
                 },
                 reduce_op(%{
                   "payment_operation_id" => "pay-92",
                   "amount_cents" => 500,
                   "occurred_on" => "2026-10-07"
                 }),
                 cancel_rooms_op(%{"group_id" => "group-92", "occurred_on" => "2026-10-08"}),
                 charge_back_op(%{
                   "payment_operation_id" => "pay-src",
                   "occurred_on" => "2026-10-08"
                 }),
                 cancel_op(%{"group_id" => "group-81", "occurred_on" => "2026-10-08"})
               ]),
               &(&1["status"] == "applied")
             )

      assert raw_reports(~D[2026-10-05], ~D[2026-10-09]) == closed

      close("2026-10-12")
      pay("pay-late", "group-92", 100, "2026-10-01")

      assert raw_reports(~D[2026-10-05], ~D[2026-10-09]) == closed

      # The lot expiring 2027-10-07 is still open; it may change until it is closed.
      close("2027-10-07")
      closed_expiry = raw_report("2027-10-07")

      submit_one(cancel_op(%{"group_id" => "group-92", "occurred_on" => "2026-10-08"}))

      assert raw_report("2027-10-07") == closed_expiry
      assert raw_reports(~D[2026-10-05], ~D[2026-10-09]) == closed

      assert_consistent(~D[2026-10-05], ~D[2026-10-14])
      assert_consistent(~D[2027-10-06], ~D[2027-10-09])
      assert_reconciles("2027-10-09")
    end
  end
end
