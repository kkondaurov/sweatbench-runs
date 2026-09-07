defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.OperationFixtures

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Finance.{Entry, PeriodClose}

  test "close validates its cutoff, has no group guard, and durably remembers every outcome", %{
    conn: conn
  } do
    premature = close_period()
    assert [%{"code" => "invalid_period"} = rejected] = submit(conn, [premature])
    submit(conn, [open_group(), payment(), start_reporting()])

    for date <- [
          nil,
          "bad",
          "2026-02-29",
          "2026-11-01T00:00:00Z",
          20_261_101,
          [],
          %{},
          true,
          "2026-10-31"
        ] do
      assert [%{"code" => "invalid_period"}] =
               submit(conn, [close_period(%{"period_end_on" => date})])
    end

    assert [%{"code" => "invalid_period"}] =
             submit(conn, [Map.delete(close_period(), "period_end_on")])

    assert [%{"code" => "invalid_operation"}] =
             submit(conn, [Map.delete(close_period(), "occurred_on")])

    assert Repo.all(PeriodClose) == []
    group = Reservations.get_group("group-81")
    ledger = Reservations.ledger()
    entries = Repo.all(Entry)

    close =
      close_period(%{
        "period_end_on" => "2026-11-01",
        "expected_revision" => 0,
        "group_id" => "missing"
      })

    assert [result] = submit(conn, [close])

    assert result == %{
             "operation_id" => close["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-11-01"
           }

    assert Reservations.get_group("group-81") == group
    assert Reservations.ledger() == ledger
    assert Repo.all(Entry) == entries
    assert report(conn, "2026-11-01")["status"] == "closed"
    assert report(conn, "2026-11-02")["status"] == "open"

    for cutoff <- ["2026-10-31", "2026-11-01"] do
      assert [%{"code" => "invalid_period"}] =
               submit(conn, [close_period(%{"period_end_on" => cutoff})])
    end

    submit(conn, [close_period()])
    assert submit(conn, [premature, close]) == [rejected, result]

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [Map.put(close, "period_end_on", "2026-12-01")])

    assert Repo.aggregate(PeriodClose, :count) == 2

    assert conn |> get("/api/v1/operations/#{close["operation_id"]}") |> json_response(200) ==
             %{"data" => result}

    assert conn |> get("/api/v1/finance/daily-report?date=2026-10-31") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}
  end

  test "batch order fixes posting dates and later closes never move committed adjustments", %{
    conn: conn
  } do
    late = payment(%{"amount_cents" => 30, "occurred_on" => "2026-10-01"})

    results =
      submit(conn, [
        open_group(),
        payment(%{"amount_cents" => 10, "occurred_on" => "2026-12-10"}),
        start_reporting(),
        payment(%{"amount_cents" => 20, "occurred_on" => "2026-10-01"}),
        close_period(),
        late,
        payment(%{"amount_cents" => 40, "occurred_on" => "2026-12-01"}),
        payment(%{"amount_cents" => 50, "occurred_on" => "2026-12-03"}),
        payment(%{"amount_cents" => -1})
      ])

    assert List.last(results)["code"] == "invalid_amount"
    assert Enum.all?(Enum.drop(results, -1), &(&1["status"] == "applied"))

    november = report_response(conn, "2026-11-01")

    assert report(conn, "2026-11-01")["cash"] == [
             cash("ams-canal", 10, %{received_cents: 20}, 30)
           ]

    assert report(conn, "2026-11-01")["late_adjustments"] == late_adjustments()

    december = report(conn, "2026-12-01")
    assert december["cash"] == [cash("ams-canal", 30, %{received_cents: 40}, 100)]

    assert december["late_adjustments"] ==
             late_adjustments([late_cash("ams-canal", %{received_cents: 30})])

    assert report(conn, "2026-12-02")["cash"] == [cash("ams-canal", 100, %{}, 100)]

    assert report(conn, "2026-12-03")["cash"] == [
             cash("ams-canal", 100, %{received_cents: 50}, 150)
           ]

    submit(conn, [close_period(%{"period_end_on" => "2026-12-02"})])
    assert report(conn, "2026-12-01") == Map.put(december, "status", "closed")
    published = report_response(conn, "2026-12-01")
    submit(conn, [payment(%{"amount_cents" => 60, "occurred_on" => "2026-11-30"})])

    assert report(conn, "2026-12-03")["cash"] == [
             cash("ams-canal", 100, %{received_cents: 50}, 210)
           ]

    assert report(conn, "2026-12-03")["late_adjustments"] ==
             late_adjustments([late_cash("ams-canal", %{received_cents: 60})])

    assert report_response(conn, "2026-11-01") == november
    assert report_response(conn, "2026-12-01") == published

    entries = Repo.all(Entry)
    assert submit(conn, [late]) == [Enum.at(results, 5)]
    assert Repo.all(Entry) == entries
    assert_reconciled(conn, "2026-12-03")
  end

  test "late corrections preserve every signed classification at its affected property", %{
    conn: conn
  } do
    submit(conn, [
      start_reporting(),
      open_group(%{"property_id" => "a"}),
      open_group(%{"group_id" => "refund", "property_id" => "b"}),
      open_group(%{
        "group_id" => "retain",
        "property_id" => "c",
        "rate_plan" => "advance_purchase"
      }),
      open_group(%{"group_id" => "convert", "property_id" => "d"}),
      open_group(%{"group_id" => "held", "property_id" => "e"}),
      payment(%{"operation_id" => "payment", "amount_cents" => 500})
    ])

    submit(
      conn,
      for(
        id <- ~w(refund retain convert held),
        do: transfer(%{"destination_group_id" => id, "amount_cents" => 100})
      )
    )

    submit(conn, [
      cancellation(%{"group_id" => "refund"}),
      cancellation(%{"group_id" => "retain"}),
      cancellation(%{"group_id" => "convert", "refund_method" => "hotel_credit"}),
      close_period()
    ])

    published = report_response(conn, "2026-11-01")
    submit(conn, [reduction(%{"amount_cents" => 150}), chargeback()])

    daily = report(conn, "2026-12-01")

    assert daily["cash"] == [
             cash("a", 100, %{}, 0),
             cash("b", 0, %{}, 0),
             cash("c", 0, %{}, 0),
             cash("d", 0, %{}, 0),
             cash("e", 100, %{}, 0)
           ]

    assert daily["late_adjustments"] ==
             late_adjustments(
               [
                 late_cash("a", %{reduced_cents: 50, charged_back_cents: 50}),
                 late_cash("b", %{refunded_cents: -100, charged_back_cents: 100}),
                 late_cash("c", %{retained_cents: -100, charged_back_cents: 100}),
                 late_cash("d", %{converted_to_credit_cents: -100, charged_back_cents: 100}),
                 late_cash("e", %{reduced_cents: 100})
               ],
               %{revoked_cents: 110}
             )

    assert daily["credit"] == credit(110, %{}, 0)
    assert report(conn, "2026-12-02")["cash"] == []
    assert report(conn, "2026-12-02")["late_adjustments"] == late_adjustments()
    assert report_response(conn, "2026-11-01") == published
    assert_reconciled(conn, "2026-12-01")

    assert {:ok, %{reduced_cents: 150, charged_back_cents: 350, held_by_group: []}} =
             Reservations.payment_statement("payment")
  end

  test "late transfers and settlement combine with ordinary cash without changing current-state rules",
       %{conn: conn} do
    submit(conn, [
      open_group(),
      open_group(%{"group_id" => "destination", "property_id" => "aaa"}),
      payment(%{"operation_id" => "payment", "amount_cents" => 200}),
      start_reporting(),
      close_period()
    ])

    published = report_response(conn, "2026-11-30")

    submit(conn, [
      transfer(%{"amount_cents" => 100}),
      cancellation(%{"group_id" => "destination"}),
      payment(%{"amount_cents" => 50, "occurred_on" => "2026-12-01"})
    ])

    daily = report(conn, "2026-12-01")

    assert daily["cash"] == [
             cash("aaa", 0, %{}, 0),
             cash("ams-canal", 200, %{received_cents: 50}, 150)
           ]

    assert daily["late_adjustments"] ==
             late_adjustments([
               late_cash("aaa", %{transferred_in_cents: 100, refunded_cents: 100}),
               late_cash("ams-canal", %{transferred_out_cents: 100})
             ])

    assert Reservations.get_group("destination").status == :cancelled
    assert Reservations.get_group("group-81").revision == 4
    assert Reservations.get_group("destination").revision == 3

    assert {:ok, %{held_cents: 100, refunded_cents: 100}} =
             Reservations.payment_statement("payment")

    assert report_response(conn, "2026-11-30") == published
    assert_reconciled(conn, "2026-12-01")
  end

  test "closed scheduled expiry stays published when late redemption and restoration reopen liability",
       %{conn: conn} do
    seed_credit(conn)
    submit(conn, [booking(), start_reporting(), close_period(%{"period_end_on" => "2027-11-02"})])
    published = report_response(conn, "2027-11-02")
    assert report(conn, "2027-11-02")["credit"] == credit(110, %{expired_cents: 110}, 0)
    submit(conn, [credit_application(%{"amount_cents" => 80, "occurred_on" => "2027-11-01"})])
    daily = report(conn, "2027-11-03")
    assert daily["credit"] == credit(0, %{}, 80)
    assert daily["late_adjustments"] == late_adjustments([], %{expired_cents: -80})
    assert_reconciled(conn, "2027-11-03")

    submit(conn, [close_period(%{"period_end_on" => "2027-11-03"})])
    redemption = report_response(conn, "2027-11-03")
    submit(conn, [cancellation(%{"occurred_on" => "2027-11-01"})])
    assert report(conn, "2027-11-04")["credit"] == credit(80, %{}, 0)

    assert report(conn, "2027-11-04")["late_adjustments"] ==
             late_adjustments([], %{expired_cents: 80})

    assert report_response(conn, "2027-11-02") == published
    assert report_response(conn, "2027-11-03") == redemption
    assert_reconciled(conn, "2027-11-04")
  end

  test "late issuance, application, and restoration keep future scheduled expiry ordinary", %{
    conn: conn
  } do
    submit(conn, [
      booking(),
      payment(%{"amount_cents" => 100}),
      start_reporting(),
      close_period(),
      cancellation(%{"refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2026-12-01")["credit"] == credit(0, %{}, 110)

    assert report(conn, "2026-12-01")["late_adjustments"] ==
             late_adjustments(
               [late_cash("ams-canal", %{converted_to_credit_cents: 100})],
               %{issued_cents: 110}
             )

    assert report(conn, "2027-11-02")["credit"] == credit(110, %{expired_cents: 110}, 0)
    assert report(conn, "2027-11-02")["late_adjustments"] == late_adjustments()

    submit(conn, [
      booking(%{"group_id" => "destination"}),
      credit_application(%{"group_id" => "destination", "amount_cents" => 80})
    ])

    assert report(conn, "2027-11-02")["credit"] == credit(110, %{expired_cents: 30}, 80)
    submit(conn, [cancellation(%{"group_id" => "destination"})])
    assert report(conn, "2027-11-02")["credit"] == credit(110, %{expired_cents: 110}, 0)
    assert report(conn, "2027-11-02")["late_adjustments"] == late_adjustments()
    assert_reconciled(conn, "2026-12-01")
    assert_reconciled(conn, "2027-11-02")
  end

  test "backdated issuance after closed expiry reports its complete zero-net credit effect", %{
    conn: conn
  } do
    submit(conn, [
      booking(),
      payment(%{"amount_cents" => 100}),
      start_reporting(),
      close_period(%{"period_end_on" => "2027-11-02"})
    ])

    published = report_response(conn, "2027-11-02")
    submit(conn, [cancellation(%{"refund_method" => "hotel_credit"})])
    assert report(conn, "2027-11-03")["credit"] == credit(0, %{}, 0)

    assert report(conn, "2027-11-03")["late_adjustments"] ==
             late_adjustments(
               [late_cash("ams-canal", %{converted_to_credit_cents: 100})],
               %{issued_cents: 110, expired_cents: 110}
             )

    assert report_response(conn, "2027-11-02") == published
    assert_reconciled(conn, "2027-11-03")
  end

  test "late clawback absorption and consumption reduce applied liability exactly once", %{
    conn: conn
  } do
    seed_credit(conn)

    submit(conn, [
      booking(),
      credit_application(%{"amount_cents" => 100}),
      start_reporting(),
      close_period(),
      chargeback(%{"payment_operation_id" => "seed-payment"})
    ])

    assert Reservations.ledger(~D[2026-12-01]).credit_shortfall_cents == 100

    submit(conn, [
      room_cancellation(%{"room_ids" => ["first"]}),
      cancellation(%{"occurred_on" => "2028-02-01"}),
      close_period(%{"period_end_on" => "2028-02-02"})
    ])

    assert report(conn, "2026-12-01")["late_adjustments"]["credit"] ==
             credit_movements(%{revoked_cents: 10, absorbed_cents: 50})

    assert report(conn, "2028-02-01")["credit"] == credit(50, %{consumed_cents: 50}, 0)
    assert_reconciled(conn, "2028-02-02")
  end

  test "late revocation reclassifies published expiry and cancellation consumes applied credit",
       %{conn: conn} do
    seed_credit(conn)

    submit(conn, [
      booking(%{"rate_plan" => "advance_purchase"}),
      credit_application(%{"amount_cents" => 80}),
      start_reporting(),
      close_period(%{"period_end_on" => "2027-11-02"})
    ])

    published = report_response(conn, "2027-11-02")
    submit(conn, [chargeback(%{"payment_operation_id" => "seed-payment"}), cancellation()])
    assert report(conn, "2027-11-03")["credit"] == credit(80, %{}, 0)

    assert report(conn, "2027-11-03")["late_adjustments"]["credit"] ==
             credit_movements(%{consumed_cents: 80, expired_cents: -30, revoked_cents: 30})

    assert report_response(conn, "2027-11-02") == published
    assert_reconciled(conn, "2027-11-03")
  end

  test "revocation dated after expiry adds no second liability reduction after a close", %{
    conn: conn
  } do
    seed_credit(conn)
    submit(conn, [start_reporting(), close_period(%{"period_end_on" => "2027-11-03"})])
    published = report_response(conn, "2027-11-02")

    assert [%{"status" => "applied"}] =
             submit(conn, [
               chargeback(%{
                 "payment_operation_id" => "seed-payment",
                 "occurred_on" => "2027-11-02"
               })
             ])

    assert report(conn, "2027-11-04")["credit"] == credit(0, %{}, 0)
    assert report(conn, "2027-11-04")["late_adjustments"]["credit"] == credit_movements(%{})
    assert report_response(conn, "2027-11-02") == published
    assert_reconciled(conn, "2027-11-04")
  end

  test "late movements preserve exact cents above SQLite's aggregate range", %{conn: conn} do
    amount = 8_000_000_000_000_000_000
    submit(conn, [start_reporting(), close_period()])

    for id <- ~w(first second third) do
      assert [%{"status" => "applied"}, %{"status" => "applied"}] =
               submit(conn, [
                 open_group(%{
                   "group_id" => id,
                   "rate_plan" => "advance_purchase",
                   "arrival_on" => "2026-12-10",
                   "departure_on" => "2026-12-11",
                   "rooms" => [%{"room_id" => "only", "nightly_rate_cents" => amount}]
                 }),
                 payment(%{"group_id" => id, "amount_cents" => amount})
               ])
    end

    daily = report(conn, "2026-12-01")
    assert daily["cash"] == [cash("ams-canal", 0, %{}, 3 * amount)]

    assert daily["late_adjustments"] ==
             late_adjustments([late_cash("ams-canal", %{received_cents: 3 * amount})])

    assert_reconciled(conn, "2026-12-01")

    submit(conn, [close_period(%{"period_end_on" => "2026-12-01"})])
    published = report_response(conn, "2026-12-01")

    for id <- ~w(first second third) do
      assert [%{"status" => "applied"}] = submit(conn, [cancellation(%{"group_id" => id})])
    end

    assert report(conn, "2026-12-02")["cash"] == [cash("ams-canal", 3 * amount, %{}, 0)]

    assert report(conn, "2026-12-02")["late_adjustments"] ==
             late_adjustments([late_cash("ams-canal", %{retained_cents: 3 * amount})])

    assert report_response(conn, "2026-12-01") == published
    assert_reconciled(conn, "2026-12-02")
  end

  defp booking(overrides \\ %{}) do
    open_group(
      Map.merge(
        %{
          "arrival_on" => "2028-02-01",
          "departure_on" => "2028-02-02",
          "rooms" =>
            Enum.map(~w(first second third), &%{"room_id" => &1, "nightly_rate_cents" => 250})
        },
        overrides
      )
    )
  end

  defp seed_credit(conn) do
    submit(conn, [
      booking(%{"group_id" => "seed"}),
      payment(%{"group_id" => "seed", "operation_id" => "seed-payment", "amount_cents" => 100}),
      cancellation(%{"group_id" => "seed", "refund_method" => "hotel_credit"})
    ])
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report_response(conn, date) do
    conn = get(conn, "/api/v1/finance/daily-report", %{"date" => date})
    assert conn.status == 200
    conn.resp_body
  end

  defp report(conn, date),
    do: report_response(conn, date) |> Jason.decode!() |> Map.fetch!("data")

  defp cash(property, opening, movements, closing) do
    %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "closing_held_cents" => closing,
      "movements" => cash_movements(movements)
    }
  end

  defp credit(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "closing_liability_cents" => closing,
      "movements" => credit_movements(movements)
    }
  end

  defp late_cash(property, movements),
    do: %{"property_id" => property, "movements" => cash_movements(movements)}

  defp late_adjustments(cash \\ [], credit \\ %{}),
    do: %{"cash" => cash, "credit" => credit_movements(credit)}

  defp cash_movements(overrides),
    do:
      movements(
        ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
        overrides
      )

  defp credit_movements(overrides),
    do:
      movements(
        ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents),
        overrides
      )

  defp movements(columns, overrides),
    do:
      Map.merge(
        Map.new(columns, &{&1, 0}),
        Map.new(overrides, fn {key, amount} -> {to_string(key), amount} end)
      )

  defp assert_reconciled(conn, date) do
    report = report(conn, date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents

    for row <- report["cash"] do
      late =
        Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == row["property_id"]))

      total =
        Map.merge(row["movements"], if(late, do: late["movements"], else: %{}), fn _, a, b ->
          a + b
        end)

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + total["received_cents"] + total["transferred_in_cents"] -
                 Enum.sum(Map.values(Map.drop(total, ~w(received_cents transferred_in_cents))))
    end
  end
end
