defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Finance.{Entry, ReportingStart}
  alias GroupStay.Reservations.{CreditLot, Group, OperationRecord}

  test "report dates are required and reporting must have started", %{conn: conn} do
    for params <- [
          %{},
          %{"date" => ""},
          %{"date" => "2026-02-30"},
          %{"date" => []},
          %{"date" => "2026-11-01T00:00:00Z"}
        ] do
      assert conn |> get("/api/v1/finance/daily-report", params) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert conn |> get("/api/v1/finance/daily-report?date=2026-11-01") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    submit(conn, [start_reporting()])

    assert conn |> get("/api/v1/finance/daily-report?date=2026-10-31") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    assert report(conn, "2026-11-01") == %{
             "date" => "2026-11-01",
             "status" => "open",
             "cash" => [],
             "credit" => credit(0, %{}, 0)
           }
  end

  test "start validates its date, ignores revisions, and durably replays successes and rejections",
       %{conn: conn} do
    invalid = start_reporting() |> Map.delete("starts_on")
    assert [%{"code" => "invalid_reporting_date"} = rejected] = submit(conn, [invalid])

    for date <- [nil, "bad", "2026-02-29", "2026-11-01T00:00:00Z", 20_261_101, [], %{}, true] do
      assert [%{"code" => "invalid_reporting_date"}] =
               submit(conn, [start_reporting(%{"starts_on" => date})])
    end

    assert Repo.all(Entry) == []
    assert Repo.all(ReportingStart) == []
    submit(conn, [booking("group-81")])
    group = Reservations.get_group("group-81")
    operation = start_reporting(%{"expected_revision" => 0, "destination_expected_revision" => 0})

    assert [result] = submit(conn, [operation])

    assert result == %{
             "operation_id" => operation["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-11-01"
           }

    assert Reservations.get_group("group-81") == group
    assert submit(conn, [invalid, operation]) == [rejected, result]

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [Map.put(operation, "starts_on", "2026-11-02")])

    assert [%{"code" => "reporting_already_started"}] = submit(conn, [start_reporting()])

    assert conn |> get("/api/v1/operations/#{operation["operation_id"]}") |> json_response(200) ==
             %{"data" => result}

    assert Repo.aggregate(ReportingStart, :count) == 1
  end

  test "inception captures commit order, later postings clamp to start, and late cash revises open days",
       %{conn: conn} do
    start = start_reporting()
    after_start = payment(%{"amount_cents" => 50, "occurred_on" => "2026-10-01"})

    submit(conn, [
      booking("group-81"),
      payment(%{"amount_cents" => 100, "occurred_on" => "2026-12-01"}),
      booking("second", %{"property_id" => "aaa"}),
      payment(%{"group_id" => "second", "amount_cents" => 20}),
      booking("unfunded", %{"property_id" => "omit-me"}),
      start,
      after_start,
      payment(%{"amount_cents" => 40, "occurred_on" => "2026-11-03"})
    ])

    assert report(conn, "2026-11-01")["cash"] == [
             cash("aaa", 20, %{}, 20),
             cash("ams-canal", 100, %{"received_cents" => 50}, 150)
           ]

    assert report(conn, "2026-11-02")["cash"] == [
             cash("aaa", 20, %{}, 20),
             cash("ams-canal", 150, %{}, 150)
           ]

    late = payment(%{"amount_cents" => 10, "occurred_on" => "2026-11-02"})

    assert [%{"status" => "applied"}, %{"code" => "invalid_amount"}] =
             submit(conn, [late, payment(%{"amount_cents" => -1})])

    assert report(conn, "2026-11-02")["cash"] == [
             cash("aaa", 20, %{}, 20),
             cash("ams-canal", 150, %{"received_cents" => 10}, 160)
           ]

    assert report(conn, "2026-11-03")["cash"] == [
             cash("aaa", 20, %{}, 20),
             cash("ams-canal", 160, %{"received_cents" => 40}, 200)
           ]

    before = Repo.all(Entry)
    submit(conn, [start, after_start, late])
    assert Repo.all(Entry) == before
    assert_reconciled(conn, "2026-12-01")
  end

  test "cash corrections follow held and settled allocations across every property", %{conn: conn} do
    submit(conn, [
      start_reporting(),
      booking("group-81", %{"property_id" => "a", "rate_plan" => "advance_purchase"}),
      booking("refund", %{"property_id" => "b"}),
      booking("retain", %{"property_id" => "c", "rate_plan" => "advance_purchase"}),
      booking("convert", %{"property_id" => "d"}),
      booking("held", %{"property_id" => "e"}),
      payment(%{"operation_id" => "payment", "amount_cents" => 500})
    ])

    submit(
      conn,
      for(
        id <- ~w(refund retain convert held),
        do: transfer(%{"destination_group_id" => id, "amount_cents" => 100})
      )
    )

    assert report(conn, "2026-11-01")["cash"] == [
             cash("a", 0, %{"received_cents" => 500, "transferred_out_cents" => 400}, 100)
             | Enum.map(~w(b c d e), &cash(&1, 0, %{"transferred_in_cents" => 100}, 100))
           ]

    submit(conn, [
      cancellation(%{"group_id" => "refund", "occurred_on" => "2026-11-02"}),
      cancellation(%{"group_id" => "retain", "occurred_on" => "2026-11-02"}),
      cancellation(%{
        "group_id" => "convert",
        "occurred_on" => "2026-11-02",
        "refund_method" => "hotel_credit"
      })
    ])

    assert report(conn, "2026-11-02")["cash"] == [
             cash("a", 100, %{}, 100),
             cash("b", 100, %{"refunded_cents" => 100}, 0),
             cash("c", 100, %{"retained_cents" => 100}, 0),
             cash("d", 100, %{"converted_to_credit_cents" => 100}, 0),
             cash("e", 100, %{}, 100)
           ]

    assert report(conn, "2026-11-02")["credit"] == credit(0, %{"issued_cents" => 110}, 110)

    submit(conn, [reduction(%{"amount_cents" => 150, "occurred_on" => "2026-11-03"})])

    assert report(conn, "2026-11-03")["cash"] == [
             cash("a", 100, %{"reduced_cents" => 50}, 50),
             cash("e", 100, %{"reduced_cents" => 100}, 0)
           ]

    assert_reconciled(conn, "2026-11-03")

    submit(conn, [chargeback(%{"occurred_on" => "2026-11-04"})])

    assert report(conn, "2026-11-04")["cash"] == [
             cash("a", 50, %{"charged_back_cents" => 50}, 0),
             cash("b", 0, %{"refunded_cents" => -100, "charged_back_cents" => 100}, 0),
             cash("c", 0, %{"retained_cents" => -100, "charged_back_cents" => 100}, 0),
             cash("d", 0, %{"converted_to_credit_cents" => -100, "charged_back_cents" => 100}, 0)
           ]

    assert report(conn, "2026-11-04")["credit"] == credit(110, %{"revoked_cents" => 110}, 0)
    assert report(conn, "2026-11-05")["cash"] == []
    assert_reconciled(conn, "2026-11-04")

    assert {:ok, %{reduced_cents: 150, charged_back_cents: 350}} =
             Reservations.payment_statement("payment")
  end

  test "same-property mixed transfers report only cash and selected rooms settle separately", %{
    conn: conn
  } do
    seed_credit(conn, 100)

    submit(conn, [
      start_reporting(),
      booking("group-81"),
      booking("destination"),
      credit_application(%{"amount_cents" => 100}),
      payment(%{"amount_cents" => 150}),
      transfer(%{"amount_cents" => 180}),
      room_cancellation(%{"group_id" => "destination", "room_ids" => ["z"]})
    ])

    assert report(conn, "2026-11-01")["cash"] == [
             cash(
               "ams-canal",
               0,
               %{
                 "received_cents" => 150,
                 "transferred_in_cents" => 150,
                 "transferred_out_cents" => 150,
                 "refunded_cents" => 100
               },
               50
             )
           ]

    assert report(conn, "2026-11-01")["credit"] == credit(110, %{}, 110)
    assert_reconciled(conn, "2026-11-01")
  end

  test "unused credit expires without an operation and reads neither materialize expiry nor rewrite history",
       %{conn: conn} do
    seed_credit(conn, 100)

    submit(conn, [
      booking("group-81"),
      credit_application(%{"amount_cents" => 80}),
      start_reporting()
    ])

    before = snapshot()

    assert report(conn, "2027-11-02")["credit"] == credit(110, %{"expired_cents" => 30}, 80)
    assert report(conn, "2027-11-01")["credit"] == credit(110, %{}, 110)
    assert report(conn, "2027-11-03")["credit"] == credit(80, %{}, 80)
    assert report(conn, "2027-11-02")["credit"] == credit(110, %{"expired_cents" => 30}, 80)
    assert snapshot() == before
    assert_reconciled(conn, "2027-11-02")

    submit(conn, [cancellation(%{"occurred_on" => "2027-12-01"})])
    assert report(conn, "2027-12-01")["credit"] == credit(80, %{"expired_cents" => 80}, 0)
    assert report(conn, "2027-11-02")["credit"] == credit(110, %{"expired_cents" => 30}, 80)
    assert_reconciled(conn, "2027-12-01")
  end

  test "issuance rounds combined rooms once and restored credit gets no second bonus", %{
    conn: conn
  } do
    submit(conn, [
      start_reporting(),
      booking("seed", %{
        "rooms" => [
          %{"room_id" => "x", "nightly_rate_cents" => 25},
          %{"room_id" => "y", "nightly_rate_cents" => 25}
        ]
      }),
      payment(%{"group_id" => "seed", "amount_cents" => 10}),
      room_cancellation(%{
        "group_id" => "seed",
        "room_ids" => ["y", "x"],
        "refund_method" => "hotel_credit"
      }),
      booking("group-81"),
      credit_application(%{"amount_cents" => 11}),
      cancellation(%{"occurred_on" => "2026-11-02", "refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2026-11-01")["credit"] == credit(0, %{"issued_cents" => 11}, 11)
    assert report(conn, "2026-11-02")["credit"] == credit(11, %{}, 11)
    assert report(conn, "2027-11-02")["credit"] == credit(11, %{"expired_cents" => 11}, 0)
    assert_reconciled(conn, "2027-11-02")
  end

  test "clawbacks revoke unused credit, absorb returns before expiry, and consume remaining applied credit",
       %{conn: conn} do
    submit(conn, [
      booking("seed"),
      payment(%{"group_id" => "seed", "operation_id" => "first", "amount_cents" => 100}),
      payment(%{"group_id" => "seed", "operation_id" => "second", "amount_cents" => 100}),
      cancellation(%{"group_id" => "seed", "refund_method" => "hotel_credit"}),
      booking("group-81"),
      credit_application(%{"amount_cents" => 200}),
      start_reporting(),
      chargeback(%{"payment_operation_id" => "first", "occurred_on" => "2026-11-02"})
    ])

    assert report(conn, "2026-11-02")["credit"] == credit(220, %{"revoked_cents" => 20}, 200)
    assert Reservations.ledger(~D[2026-11-02]).credit_shortfall_cents == 90
    assert report(conn, "2027-11-02")["credit"] == credit(200, %{}, 200)

    submit(conn, [room_cancellation(%{"room_ids" => ["z"], "occurred_on" => "2027-12-01"})])

    assert report(conn, "2027-12-01")["credit"] ==
             credit(200, %{"absorbed_cents" => 90, "expired_cents" => 10}, 100)

    assert Reservations.ledger(~D[2027-12-01]).credit_shortfall_cents == 0

    submit(conn, [cancellation(%{"occurred_on" => "2028-02-01"})])
    assert report(conn, "2028-02-01")["credit"] == credit(100, %{"consumed_cents" => 100}, 0)
    assert_reconciled(conn, "2028-02-01")
  end

  test "inception excludes expired unused credit but includes shortfalled applied credit", %{
    conn: conn
  } do
    seed_credit(conn, 100)

    submit(conn, [
      booking("group-81"),
      credit_application(%{"amount_cents" => 80}),
      chargeback(%{"payment_operation_id" => "seed-payment"}),
      start_reporting(%{"starts_on" => "2027-12-01"})
    ])

    assert report(conn, "2027-12-01")["credit"] == credit(80, %{}, 80)
    submit(conn, [cancellation(%{"occurred_on" => "2027-12-02"})])
    assert report(conn, "2027-12-02")["credit"] == credit(80, %{"absorbed_cents" => 80}, 0)
    assert_reconciled(conn, "2027-12-02")
  end

  test "revoking expired unused entitlement does not remove liability twice", %{conn: conn} do
    seed_credit(conn, 100)

    submit(conn, [
      start_reporting(),
      chargeback(%{"payment_operation_id" => "seed-payment", "occurred_on" => "2027-12-01"})
    ])

    assert report(conn, "2027-11-02")["credit"] == credit(110, %{"expired_cents" => 110}, 0)
    assert report(conn, "2027-12-01")["credit"] == credit(0, %{}, 0)
    assert_reconciled(conn, "2027-12-01")
  end

  test "late credit redemption updates expiry and later returns post on their operation date", %{
    conn: conn
  } do
    seed_credit(conn, 100)
    submit(conn, [start_reporting(), booking("group-81")])
    assert report(conn, "2027-11-02")["credit"] == credit(110, %{"expired_cents" => 110}, 0)
    submit(conn, [credit_application(%{"amount_cents" => 80, "occurred_on" => "2027-11-01"})])
    assert report(conn, "2027-11-01")["credit"] == credit(110, %{}, 110)
    assert report(conn, "2027-11-02")["credit"] == credit(110, %{"expired_cents" => 30}, 80)
    submit(conn, [cancellation(%{"occurred_on" => "2027-11-02"})])
    assert report(conn, "2027-11-02")["credit"] == credit(110, %{"expired_cents" => 110}, 0)
    assert_reconciled(conn, "2027-11-02")
  end

  test "an expired opening lot can fund a backdated redemption clamped to inception", %{
    conn: conn
  } do
    seed_credit(conn, 100)
    submit(conn, [booking("group-81"), start_reporting(%{"starts_on" => "2027-12-01"})])
    assert report(conn, "2027-12-01")["credit"] == credit(0, %{}, 0)
    submit(conn, [credit_application(%{"amount_cents" => 80})])
    assert report(conn, "2027-12-01")["credit"] == credit(0, %{"expired_cents" => -80}, 80)
    assert_reconciled(conn, "2027-12-01")
  end

  test "property and company balances preserve exact cents above SQLite's aggregate range", %{
    conn: conn
  } do
    amount = 8_000_000_000_000_000_000

    for id <- ~w(first second third) do
      submit(conn, [
        booking(id, %{
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "only", "nightly_rate_cents" => amount}]
        }),
        payment(%{"group_id" => id, "amount_cents" => amount})
      ])
    end

    submit(conn, [start_reporting()])
    assert report(conn, "2026-11-01")["cash"] == [cash("ams-canal", 3 * amount, %{}, 3 * amount)]

    submit(
      conn,
      for(
        id <- ~w(first second third),
        do: cancellation(%{"group_id" => id, "occurred_on" => "2026-11-02"})
      )
    )

    assert report(conn, "2026-11-02")["cash"] == [
             cash("ams-canal", 3 * amount, %{"retained_cents" => 3 * amount}, 0)
           ]

    assert_reconciled(conn, "2026-11-02")
  end

  test "backdated conversion posts issuance and immediate expiry together at inception", %{
    conn: conn
  } do
    submit(conn, [
      booking("group-81"),
      payment(%{"amount_cents" => 100}),
      start_reporting(%{"starts_on" => "2028-01-01"}),
      cancellation(%{"refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2028-01-01")["cash"] == [
             cash("ams-canal", 100, %{"converted_to_credit_cents" => 100}, 0)
           ]

    assert report(conn, "2028-01-01")["credit"] ==
             credit(0, %{"issued_cents" => 110, "expired_cents" => 110}, 0)

    assert_reconciled(conn, "2028-01-01")
  end

  test "credit transfers preserve paused expiry and return to the original lot on settlement", %{
    conn: conn
  } do
    seed_credit(conn, 100)

    submit(conn, [
      booking("group-81"),
      credit_application(%{"amount_cents" => 110}),
      booking("destination", %{"property_id" => "other"}),
      start_reporting(),
      transfer(%{"amount_cents" => 110, "occurred_on" => "2027-12-01"})
    ])

    assert report(conn, "2027-12-01")["cash"] == []
    assert report(conn, "2027-12-01")["credit"] == credit(110, %{}, 110)

    submit(conn, [
      cancellation(%{
        "group_id" => "destination",
        "occurred_on" => "2027-12-02",
        "refund_method" => "hotel_credit"
      })
    ])

    assert report(conn, "2027-12-02")["credit"] == credit(110, %{"expired_cents" => 110}, 0)
    assert_reconciled(conn, "2027-12-02")
  end

  defp booking(id, overrides \\ %{}) do
    open_group(
      Map.merge(
        %{
          "group_id" => id,
          "arrival_on" => "2028-02-01",
          "departure_on" => "2028-02-02",
          "rooms" => Enum.map(~w(z a m), &%{"room_id" => &1, "nightly_rate_cents" => 500})
        },
        overrides
      )
    )
  end

  defp seed_credit(conn, amount) do
    submit(conn, [
      booking("seed"),
      payment(%{
        "group_id" => "seed",
        "operation_id" => "seed-payment",
        "amount_cents" => amount
      }),
      cancellation(%{
        "group_id" => "seed",
        "operation_id" => "seed-lot",
        "refund_method" => "hotel_credit"
      })
    ])
  end

  defp submit(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp report(conn, date),
    do:
      conn
      |> get("/api/v1/finance/daily-report", %{"date" => date})
      |> json_response(200)
      |> Map.fetch!("data")

  defp cash(property, opening, movements, closing) do
    %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "closing_held_cents" => closing,
      "movements" =>
        Map.merge(
          Map.new(
            ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
            &{&1, 0}
          ),
          movements
        )
    }
  end

  defp credit(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "closing_liability_cents" => closing,
      "movements" =>
        Map.merge(
          Map.new(
            ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents),
            &{&1, 0}
          ),
          movements
        )
    }
  end

  defp assert_reconciled(conn, date) do
    report = report(conn, date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents

    assert Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))

    for row <- report["cash"] do
      amounts = row["movements"]

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + amounts["received_cents"] +
                 amounts["transferred_in_cents"] -
                 Enum.sum(Map.values(Map.drop(amounts, ~w(received_cents transferred_in_cents))))
    end
  end

  defp snapshot,
    do: Enum.map([Entry, ReportingStart, Group, CreditLot, OperationRecord], &Repo.all/1)
end
