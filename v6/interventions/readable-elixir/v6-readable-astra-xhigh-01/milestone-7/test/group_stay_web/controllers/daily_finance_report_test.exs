defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerFixtures

  alias GroupStay.{Finance, Operations, Repo, Reservations}
  alias GroupStay.Finance.Reporting.{Entry, Inception}

  @cash_keys ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_keys ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  test "the report requires a valid date and an available inception" do
    for query <- [
          "",
          "?date=bad",
          "?date=2026-02-30",
          "?date[]=2026-10-03",
          "?date[x]=2026-10-03"
        ] do
      assert error_report(query, 422) == "invalid_reporting_date"
    end

    assert error_report("?date=2026-10-03", 404) == "report_not_available"
    apply!([start_reporting()])
    assert error_report("?date=2026-10-02", 404) == "report_not_available"

    assert report("2026-10-03") == %{
             "date" => "2026-10-03",
             "status" => "open",
             "cash" => [],
             "credit" => credit(0, %{}, 0),
             "late_adjustments" => %{"cash" => [], "credit" => Map.new(@credit_keys, &{&1, 0})}
           }
  end

  test "start validates and durably remembers dates, ignores revision guards, and has an exact result" do
    for value <- [nil, 123, [], %{}, "", "2026-02-29"] do
      invalid = start_reporting(%{"starts_on" => value})
      [rejection] = submit([invalid])
      assert rejection["code"] == "invalid_reporting_date"
      assert submit([invalid]) == [rejection]

      assert [%{"code" => "operation_id_conflict"}] =
               submit([Map.put(invalid, "starts_on", "2026-10-03")])
    end

    assert [%{"code" => "invalid_reporting_date"}] =
             submit([Map.delete(start_reporting(), "starts_on")])

    start = start_reporting(%{"expected_revision" => -1})
    [result] = apply!([start])

    assert result == %{
             "operation_id" => start["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-10-03"
           }

    assert submit([start]) == [result]
    assert Operations.get_result(start["operation_id"]) == result
    assert [%{"code" => "reporting_already_started"}] = submit([start_reporting()])
    assert Repo.aggregate(Inception, :count) == 1
    assert Repo.all(Entry) == []
  end

  test "inception includes prior commits regardless of dates and splits the same batch precisely" do
    apply!([
      booking("source", "z-property"),
      cash("source", "prior-future", 1000, "2026-12-01"),
      booking("empty", "empty-property"),
      booking("other", "a-property"),
      start_reporting(),
      cash("source", "after", 500),
      cash("other", "backdated", 200, "2026-01-01")
    ])

    first = report("2026-10-03")

    assert first["cash"] == [
             cash_row("a-property", 0, %{"received_cents" => 200}, 200),
             cash_row("z-property", 1000, %{"received_cents" => 500}, 1500)
           ]

    assert report("2026-12-01")["cash"] == [
             cash_row("a-property", 200, %{}, 200),
             cash_row("z-property", 1500, %{}, 1500)
           ]

    assert Reservations.get_group("source").revision == 3

    apply!([cash("source", "later-submission", 100, "2026-10-03")])

    assert report("2026-10-03")["cash"] == [
             cash_row("a-property", 0, %{"received_cents" => 200}, 200),
             cash_row("z-property", 1000, %{"received_cents" => 600}, 1600)
           ]

    assert_reconciles("2026-12-02")
  end

  test "transfers and corrections follow the holding and settlement properties" do
    apply!([
      start_reporting(),
      booking("source", "source"),
      booking("refund", "refund"),
      booking("retain", "retain", %{"rate_plan" => "advance_purchase"}),
      cash("source", "payment", 3000),
      transfer_deposit("source", "refund", 1200, %{"occurred_on" => "2026-10-04"}),
      transfer_deposit("source", "retain", 800, %{"occurred_on" => "2026-10-04"}),
      operation("cancel_rooms", %{
        "group_id" => "refund",
        "room_ids" => ["r-0"],
        "occurred_on" => "2026-10-05"
      }),
      operation("cancel_group", %{"group_id" => "retain", "occurred_on" => "2026-10-05"}),
      correction("reduce_cash_payment", "payment", "2026-10-06", %{"amount_cents" => 400}),
      correction("charge_back_payment", "payment", "2026-10-07")
    ])

    assert report("2026-10-04")["cash"] == [
             cash_row("refund", 0, %{"transferred_in_cents" => 1200}, 1200),
             cash_row("retain", 0, %{"transferred_in_cents" => 800}, 800),
             cash_row("source", 3000, %{"transferred_out_cents" => 2000}, 1000)
           ]

    assert report("2026-10-05")["cash"] == [
             cash_row("refund", 1200, %{"refunded_cents" => 1000}, 200),
             cash_row("retain", 800, %{"retained_cents" => 800}, 0),
             cash_row("source", 1000, %{}, 1000)
           ]

    assert report("2026-10-06")["cash"] == [
             cash_row("refund", 200, %{"reduced_cents" => 200}, 0),
             cash_row("source", 1000, %{"reduced_cents" => 200}, 800)
           ]

    assert report("2026-10-07")["cash"] == [
             cash_row("refund", 0, %{"refunded_cents" => -1000, "charged_back_cents" => 1000}, 0),
             cash_row("retain", 0, %{"retained_cents" => -800, "charged_back_cents" => 800}, 0),
             cash_row("source", 800, %{"charged_back_cents" => 800}, 0)
           ]

    assert report("2026-10-08")["cash"] == []
    assert_reconciles("2026-10-08")
  end

  test "same-property transfers retain both columns and zero net cash days remain visible" do
    apply!([
      start_reporting(),
      booking("source", "same"),
      booking("dest", "same"),
      cash("source", "payment", 100),
      transfer_deposit("source", "dest", 100),
      operation("cancel_group", %{"group_id" => "dest"})
    ])

    assert report("2026-10-03")["cash"] == [
             cash_row(
               "same",
               0,
               %{
                 "received_cents" => 100,
                 "transferred_in_cents" => 100,
                 "transferred_out_cents" => 100,
                 "refunded_cents" => 100
               },
               0
             )
           ]

    assert report("2026-10-04")["cash"] == []
  end

  test "expiry occurs without submissions, and late applications adjust an already read open report" do
    apply!([
      start_reporting(),
      booking("issuer", "issuer"),
      cash("issuer", "payment", 100),
      operation("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
      booking("recipient", "recipient")
    ])

    assert report("2026-10-03")["credit"] == credit(0, %{"issued_cents" => 110}, 110)
    assert report("2027-10-03")["credit"] == credit(110, %{}, 110)
    assert report("2027-10-04")["credit"] == credit(110, %{"expired_cents" => 110}, 0)

    apply!([
      operation("apply_hotel_credit", %{
        "group_id" => "recipient",
        "amount_cents" => 60,
        "occurred_on" => "2027-10-03"
      })
    ])

    assert report("2027-10-03")["credit"] == credit(110, %{}, 110)
    assert report("2027-10-04")["credit"] == credit(110, %{"expired_cents" => 50}, 60)

    apply!([
      operation("cancel_group", %{"group_id" => "recipient", "occurred_on" => "2027-10-06"})
    ])

    assert report("2027-10-06")["credit"] == credit(60, %{"expired_cents" => 60}, 0)
    assert report("2027-10-04")["credit"] == credit(110, %{"expired_cents" => 50}, 60)

    before = storage_snapshot()
    expected = Enum.map(~w(2027-10-06 2026-10-03 2027-10-04 2027-10-03), &report/1)

    assert Enum.map(~w(2027-10-03 2027-10-04 2026-10-03 2027-10-06), &report/1) ==
             Enum.reverse(expected)

    assert storage_snapshot() == before
    assert_reconciles("2027-10-06")
  end

  test "mixed transfers pause credit expiry and destination conversion is reversed at that property" do
    apply!([
      start_reporting(),
      booking("issuer", "issuer"),
      cash("issuer", "issuer-pay", 100),
      operation("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
      booking("source", "source"),
      cash("source", "payment", 100),
      operation("apply_hotel_credit", %{"group_id" => "source", "amount_cents" => 110}),
      booking("dest", "dest"),
      transfer_deposit("source", "dest", 160, %{"occurred_on" => "2027-10-04"}),
      operation("cancel_group", %{
        "group_id" => "dest",
        "occurred_on" => "2027-10-05",
        "refund_method" => "hotel_credit"
      }),
      correction("charge_back_payment", "payment", "2027-10-06")
    ])

    assert report("2027-10-04")["credit"] == credit(110, %{}, 110)

    assert report("2027-10-04")["cash"] == [
             cash_row("dest", 0, %{"transferred_in_cents" => 50}, 50),
             cash_row("source", 100, %{"transferred_out_cents" => 50}, 50)
           ]

    assert report("2027-10-05")["credit"] ==
             credit(110, %{"issued_cents" => 55, "expired_cents" => 110}, 55)

    assert report("2027-10-06")["cash"] == [
             cash_row(
               "dest",
               0,
               %{"converted_to_credit_cents" => -50, "charged_back_cents" => 50},
               0
             ),
             cash_row("source", 50, %{"charged_back_cents" => 50}, 0)
           ]

    assert report("2027-10-06")["credit"] == credit(55, %{"revoked_cents" => 55}, 0)
    assert report("2028-10-05")["credit"] == credit(0, %{}, 0)
    assert_reconciles("2028-10-05")
  end

  for {restoration_date, expired} <- [{"2026-10-05", 0}, {"2027-10-05", 20}] do
    test "shortfall absorption precedes restoration expiry on #{restoration_date}" do
      apply!([
        start_reporting(),
        booking("issuer", "issuer"),
        cash("issuer", "first", 100),
        cash("issuer", "second", 200),
        operation("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
        booking("recipient", "recipient", %{
          "rooms" => Enum.map(0..2, &%{"room_id" => "r-#{&1}", "nightly_rate_cents" => 500})
        }),
        operation("apply_hotel_credit", %{"group_id" => "recipient", "amount_cents" => 300}),
        correction("charge_back_payment", "first", "2026-10-04"),
        operation("cancel_rooms", %{
          "group_id" => "recipient",
          "room_ids" => ["r-0"],
          "occurred_on" => unquote(restoration_date)
        })
      ])

      assert report("2026-10-04")["credit"] == credit(330, %{"revoked_cents" => 30}, 300)

      assert report(unquote(restoration_date))["credit"] ==
               credit(
                 300,
                 %{"absorbed_cents" => 80, "expired_cents" => unquote(expired)},
                 220 - unquote(expired)
               )

      assert Finance.totals(Date.from_iso8601!(unquote(restoration_date))).credit_shortfall_cents ==
               0

      assert_reconciles(unquote(restoration_date))
      assert report("2027-10-06")["credit"]["closing_liability_cents"] == 200
    end
  end

  test "restored unexpired credit expires once, and non-refundable credit is consumed" do
    apply!([
      start_reporting(),
      booking("issuer", "issuer"),
      cash("issuer", "payment", 100),
      operation("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
      booking("refundable", "refundable"),
      booking("nonrefundable", "nonrefundable", %{"rate_plan" => "advance_purchase"}),
      operation("apply_hotel_credit", %{"group_id" => "refundable", "amount_cents" => 60}),
      transfer_deposit("refundable", "nonrefundable", 20, %{"occurred_on" => "2026-10-04"}),
      operation("cancel_group", %{"group_id" => "refundable", "occurred_on" => "2026-10-05"}),
      operation("cancel_group", %{"group_id" => "nonrefundable", "occurred_on" => "2026-10-06"})
    ])

    assert report("2026-10-04")["cash"] == []
    assert report("2026-10-04")["credit"] == credit(110, %{}, 110)
    assert report("2026-10-05")["credit"] == credit(110, %{}, 110)
    assert report("2026-10-06")["credit"] == credit(110, %{"consumed_cents" => 20}, 90)
    assert report("2027-10-04")["credit"] == credit(90, %{"expired_cents" => 90}, 0)
    assert_reconciles("2027-10-04")
  end

  test "opening credit includes applied expired lots and shortfall but excludes unused expired lots" do
    apply!([
      booking("issuer", "issuer"),
      cash("issuer", "first", 100),
      cash("issuer", "second", 100),
      operation("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
      booking("recipient", "recipient"),
      operation("apply_hotel_credit", %{"group_id" => "recipient", "amount_cents" => 200}),
      correction("charge_back_payment", "first", "2026-10-04"),
      booking("unused", "unused"),
      cash("unused", "unused-pay", 100),
      operation("cancel_group", %{"group_id" => "unused", "refund_method" => "hotel_credit"}),
      start_reporting(%{"starts_on" => "2027-10-04"})
    ])

    assert report("2027-10-04")["credit"] == credit(200, %{}, 200)
    assert Repo.all(Entry) == []
    apply!([correction("charge_back_payment", "unused-pay", "2027-10-05")])
    assert report("2027-10-05")["credit"] == credit(200, %{}, 200)
    assert_reconciles("2027-10-05")
  end

  test "posting clamps all credit effects, including already expired issuance and restoration" do
    apply!([
      booking("issuer", "issuer"),
      cash("issuer", "payment", 100),
      start_reporting(%{"starts_on" => "2028-01-01"}),
      operation("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
      booking("recipient", "recipient"),
      operation("apply_hotel_credit", %{"group_id" => "recipient", "amount_cents" => 60})
    ])

    assert report("2028-01-01")["credit"] ==
             credit(0, %{"issued_cents" => 110, "expired_cents" => 50}, 60)

    assert_reconciles("2028-01-01")
    apply!([operation("cancel_group", %{"group_id" => "recipient"})])

    assert report("2028-01-01")["credit"] ==
             credit(0, %{"issued_cents" => 110, "expired_cents" => 110}, 0)

    assert_reconciles("2028-01-01")
  end

  test "rejections, exact retries, conflicts, and batch continuation never duplicate movements" do
    payment = cash("source", "payment", 100)
    transfer = transfer_deposit("source", "dest", 40)
    rejected = cash("source", "rejected", 9000)

    operations = [
      start_reporting(),
      booking("source", "source"),
      booking("dest", "dest"),
      payment,
      transfer,
      rejected,
      cash("source", "last", 20)
    ]

    results = submit(operations)

    assert Enum.map(results, & &1["status"]) ==
             ~w(applied applied applied applied applied rejected applied)

    before = storage_snapshot()
    assert submit(operations) == results
    assert [%{"code" => "operation_id_conflict"}] = submit([Map.put(payment, "amount_cents", 50)])
    assert storage_snapshot() == before

    assert report("2026-10-03")["cash"] == [
             cash_row("dest", 0, %{"transferred_in_cents" => 40}, 40),
             cash_row("source", 0, %{"received_cents" => 120, "transferred_out_cents" => 40}, 80)
           ]
  end

  test "opening positions and summed movements remain exact beyond SQLite's integer range" do
    maximum = 9_223_372_036_854_775_807
    rooms = [%{"room_id" => "large", "nightly_rate_cents" => maximum}]
    principal = div(maximum, 5)
    liability = 6 * (principal + div(principal + 5, 10))

    for index <- 1..6 do
      id = "issuer-#{index}"

      apply!([
        booking(id, "credit-property", %{"rooms" => rooms}),
        cash(id, "credit-pay-#{index}", principal),
        operation("cancel_group", %{"group_id" => id, "refund_method" => "hotel_credit"})
      ])
    end

    for index <- 1..2 do
      id = "cash-#{index}"

      apply!([
        booking(id, "cash-property", %{"rooms" => rooms, "rate_plan" => "advance_purchase"}),
        cash(id, "cash-pay-#{index}", maximum)
      ])
    end

    apply!([start_reporting()])

    for index <- 1..2 do
      apply!([
        correction("reduce_cash_payment", "cash-pay-#{index}", "2026-10-03", %{
          "amount_cents" => maximum
        }),
        cash("cash-#{index}", "refill-#{index}", maximum)
      ])
    end

    assert report("2026-10-03")["cash"] == [
             cash_row(
               "cash-property",
               2 * maximum,
               %{"received_cents" => 2 * maximum, "reduced_cents" => 2 * maximum},
               2 * maximum
             )
           ]

    assert report("2026-10-03")["credit"] == credit(liability, %{}, liability)
    assert report("2027-10-04")["credit"] == credit(liability, %{"expired_cents" => liability}, 0)
    assert_reconciles("2027-10-04")
  end

  test "credit remains available through the largest supported expiry date" do
    apply!([
      booking("issuer", "issuer", %{"arrival_on" => "9999-12-30", "departure_on" => "9999-12-31"}),
      cash("issuer", "payment", 100),
      start_reporting(%{"starts_on" => "9999-12-31"}),
      operation("cancel_group", %{
        "group_id" => "issuer",
        "refund_method" => "hotel_credit",
        "occurred_on" => "9998-12-31"
      })
    ])

    assert report("9999-12-31")["credit"] == credit(0, %{"issued_cents" => 110}, 110)
    assert_reconciles("9999-12-31")
  end

  defp booking(id, property, overrides \\ %{}) do
    open_group(%{
      "group_id" => id,
      "property_id" => property,
      "arrival_on" => "2029-12-10",
      "departure_on" => "2029-12-11",
      "rooms" => Enum.map(0..2, &%{"room_id" => "r-#{&1}", "nightly_rate_cents" => 5000})
    })
    |> Map.merge(overrides)
  end

  defp cash(group, id, amount, on \\ "2026-10-03"),
    do:
      operation("record_cash_payment", %{
        "group_id" => group,
        "operation_id" => id,
        "amount_cents" => amount,
        "occurred_on" => on
      })

  defp correction(type, payment, on, extra \\ %{}),
    do:
      operation(type, Map.merge(%{"payment_operation_id" => payment, "occurred_on" => on}, extra))
      |> Map.delete("group_id")

  defp start_reporting(overrides \\ %{}),
    do:
      operation("start_finance_reporting", Map.merge(%{"starts_on" => "2026-10-03"}, overrides))
      |> Map.delete("group_id")

  defp submit(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp apply!(operations) do
    results = submit(operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp report(date) do
    data =
      build_conn()
      |> get("/api/v1/finance/daily-report", %{"date" => date})
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.sort(Map.keys(data)) == ~w(cash credit date late_adjustments status)
    assert data["date"] == date
    assert data["status"] == "open"

    assert data["late_adjustments"] == %{
             "cash" => [],
             "credit" => Map.new(@credit_keys, &{&1, 0})
           }

    data
  end

  defp error_report(query, status),
    do:
      build_conn()
      |> get("/api/v1/finance/daily-report" <> query)
      |> json_response(status)
      |> get_in(["error", "code"])

  defp cash_row(property, opening, movements, closing),
    do: %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" => Map.merge(Map.new(@cash_keys, &{&1, 0}), movements),
      "closing_held_cents" => closing
    }

  defp credit(opening, movements, closing),
    do: %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(Map.new(@credit_keys, &{&1, 0}), movements),
      "closing_liability_cents" => closing
    }

  defp assert_reconciles(date) do
    report = report(date)
    ledger = Finance.totals(Date.from_iso8601!(date))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents

    for row <- report["cash"] do
      movements = row["movements"]
      incoming = movements["received_cents"] + movements["transferred_in_cents"]

      outgoing =
        Enum.sum(Enum.map(@cash_keys -- ~w(received_cents transferred_in_cents), &movements[&1]))

      assert row["closing_held_cents"] == row["opening_held_cents"] + incoming - outgoing
    end

    assert Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))
  end

  defp storage_snapshot do
    Map.new(
      ~w(groups rooms cash_entries cash_allocations credit_lots credit_allocations credit_entitlements operation_records finance_reporting_inceptions finance_reporting_entries),
      &{&1, Repo.query!("SELECT * FROM #{&1} ORDER BY 1").rows}
    )
  end
end
