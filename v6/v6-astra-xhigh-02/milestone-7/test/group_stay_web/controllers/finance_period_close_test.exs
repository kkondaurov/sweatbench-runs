defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false
  import GroupStay.ReservationFixtures
  alias GroupStay.{Repo, Reservations}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  test "close validates its period, ignores group guards, and durably remembers results", %{
    conn: conn
  } do
    too_early = close("2026-10-04")
    assert [%{"code" => "invalid_period"} = rejection] = batch(conn, [too_early])
    applied(conn, [start(), opening("g", "p")])
    assert batch(conn, [too_early]) == [rejection]

    invalid =
      for value <- [
            nil,
            "",
            "2026-02-29",
            "2026-10-4",
            "2026-10-04T00:00:00Z",
            123,
            true,
            [],
            %{},
            "2026-10-03"
          ],
          do: close(value)

    invalid = [Map.delete(close("2026-10-04"), "period_end_on") | invalid]
    before = snapshot()
    assert Enum.all?(batch(conn, invalid), &(&1["code"] == "invalid_period"))
    assert snapshot() == before
    assert report(conn, "2026-10-04")["status"] == "open"

    close = Map.merge(close("2026-10-04"), %{"group_id" => "missing", "expected_revision" => -1})
    [result] = applied(conn, [close])

    assert result == %{
             "operation_id" => close["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-10-04"
           }

    assert Reservations.get_group("g").revision == 1
    assert batch(conn, [close]) == [result]

    assert conn |> get("/api/v1/operations/#{close["operation_id"]}") |> json_response(200) == %{
             "data" => result
           }

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(close, "period_end_on", "2026-10-05")])

    assert Enum.all?(
             batch(conn, [close("2026-10-04"), close("2026-10-03")]),
             &(&1["code"] == "invalid_period")
           )

    assert report(conn, "2026-10-04")["status"] == "closed"
    assert report(conn, "2026-10-05")["status"] == "open"

    assert conn
           |> get("/api/v1/finance/daily-report", %{"date" => "2026-10-03"})
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
  end

  test "batch order fixes posting dates and separates ordinary and late cash through successive closes",
       %{conn: conn} do
    operations = [
      opening("g", "p"),
      pay("opening", "g", 10, "2029-01-01"),
      start(),
      pay("before", "g", 100, "2026-01-01"),
      close("2026-10-05"),
      pay("late", "g", 50, "2026-10-05"),
      pay("ordinary", "g", 25, "2026-10-06"),
      pay("future", "g", 10, "2026-10-09")
    ]

    results = applied(conn, operations)
    published = published(conn, ~w(2026-10-04 2026-10-05))
    assert report(conn, "2026-10-04")["cash"] == [cash("p", 10, %{"received_cents" => 100}, 110)]
    assert report(conn, "2026-10-06")["cash"] == [cash("p", 110, %{"received_cents" => 25}, 185)]

    assert report(conn, "2026-10-06")["late_adjustments"] ==
             adjustments([late_cash("p", %{"received_cents" => 50})])

    assert report(conn, "2026-10-07")["cash"] == [cash("p", 185, %{}, 185)]

    applied(conn, [close("2026-10-07")])
    newly_published = published(conn, ~w(2026-10-06 2026-10-07))
    bad = pay("bad", "g", -1, "2026-10-04")
    stale = pay("stale", "g", 1, "2026-10-04") |> Map.put("expected_revision", 1)
    last = pay("last", "g", 5, "2026-10-04")

    assert [
             %{"code" => "invalid_amount"},
             %{"code" => "stale_revision"},
             %{"status" => "applied"} = last_result
           ] = batch(conn, [bad, stale, last])

    assert report(conn, "2026-10-08")["cash"] == [cash("p", 185, %{}, 190)]

    assert report(conn, "2026-10-08")["late_adjustments"] ==
             adjustments([late_cash("p", %{"received_cents" => 5})])

    assert report(conn, "2026-10-09")["cash"] == [cash("p", 190, %{"received_cents" => 10}, 200)]
    assert report(conn, "2026-10-09")["late_adjustments"] == adjustments()
    before = snapshot()
    assert batch(conn, operations ++ [last]) == results ++ [last_result]
    assert snapshot() == before
    assert published(conn, Map.keys(published)) == published
    assert published(conn, Map.keys(newly_published)) == newly_published
    reconcile(conn, "2026-10-09")
  end

  test "late transfers and corrections follow every settlement property and retain signed zero-net classifications",
       %{conn: conn} do
    applied(conn, [
      start(),
      opening("s", "z"),
      opening("refund", "a"),
      opening("retain", "a", %{"rate_plan" => "advance_purchase"}),
      opening("convert", "b"),
      opening("held", "c"),
      pay("p", "s", 1000),
      close("2026-10-04")
    ])

    first = published(conn, ["2026-10-04"])

    applied(conn, [
      transfer("s", "refund", 200),
      transfer("s", "retain", 150),
      transfer("s", "convert", 100),
      transfer("s", "held", 250)
    ])

    assert report(conn, "2026-10-05")["late_adjustments"]["cash"] == [
             late_cash("a", %{"transferred_in_cents" => 350}),
             late_cash("b", %{"transferred_in_cents" => 100}),
             late_cash("c", %{"transferred_in_cents" => 250}),
             late_cash("z", %{"transferred_out_cents" => 700})
           ]

    applied(conn, [
      op("cancel_group", "refund"),
      op("cancel_group", "retain"),
      op("cancel_group", "convert", %{"refund_method" => "hotel_credit"}),
      close("2026-10-05")
    ])

    second = published(conn, ["2026-10-05"])

    assert report(conn, "2026-10-05")["late_adjustments"]["credit"] ==
             fields(@credit_fields, %{"issued_cents" => 110})

    applied(conn, [
      correction("reduce_cash_payment", "p", %{"amount_cents" => 50}),
      correction("charge_back_payment", "p")
    ])

    day = report(conn, "2026-10-06")

    assert day["cash"] == [
             cash("a", 0, %{}, 0),
             cash("b", 0, %{}, 0),
             cash("c", 250, %{}, 0),
             cash("z", 300, %{}, 0)
           ]

    assert day["late_adjustments"] ==
             adjustments(
               [
                 late_cash("a", %{
                   "refunded_cents" => -200,
                   "retained_cents" => -150,
                   "charged_back_cents" => 350
                 }),
                 late_cash("b", %{
                   "converted_to_credit_cents" => -100,
                   "charged_back_cents" => 100
                 }),
                 late_cash("c", %{"reduced_cents" => 50, "charged_back_cents" => 200}),
                 late_cash("z", %{"charged_back_cents" => 300})
               ],
               %{"revoked_cents" => 110}
             )

    assert day["credit"] == credit(110, %{}, 0)
    assert report(conn, "2026-10-07")["cash"] == []
    assert published(conn, Map.keys(first)) == first
    assert published(conn, Map.keys(second)) == second

    assert conn
           |> get("/api/v1/payments/p")
           |> json_response(200)
           |> get_in(["data", "charged_back_cents"]) == 950

    reconcile(conn, "2026-10-06")
  end

  test "a closed expiry is stable when backdated redemption restores applied liability", %{
    conn: conn
  } do
    applied(
      conn,
      [start()] ++ issue("issuer", 100) ++ [opening("target", "p"), close("2027-10-05")]
    )

    frozen = published(conn, ~w(2026-10-04 2027-10-04 2027-10-05))
    assert report(conn, "2027-10-05")["credit"] == credit(110, %{"expired_cents" => 110}, 0)

    applied(conn, [
      op("apply_hotel_credit", "target", %{"amount_cents" => 80}),
      close("2027-10-06")
    ])

    assert report(conn, "2027-10-06")["credit"] == credit(0, %{}, 80)

    assert report(conn, "2027-10-06")["late_adjustments"] ==
             adjustments([], %{"expired_cents" => -80})

    redemption = published(conn, ["2027-10-06"])
    applied(conn, [op("cancel_group", "target")])

    assert report(conn, "2027-10-07")["late_adjustments"] ==
             adjustments([], %{"expired_cents" => 80})

    assert report(conn, "2027-10-07")["credit"] == credit(80, %{}, 0)
    assert published(conn, Map.keys(frozen)) == frozen
    assert published(conn, Map.keys(redemption)) == redemption
    reconcile(conn, "2027-10-07")
  end

  test "expiry scheduled by late issuance and restoration stays ordinary on its own day", %{
    conn: conn
  } do
    applied(
      conn,
      [start(), close("2026-10-04")] ++
        issue("issuer", 100) ++
        [opening("target", "p"), op("apply_hotel_credit", "target", %{"amount_cents" => 80})]
    )

    assert report(conn, "2026-10-05")["late_adjustments"] ==
             adjustments(
               [
                 late_cash("issuer", %{
                   "received_cents" => 100,
                   "converted_to_credit_cents" => 100
                 })
               ],
               %{"issued_cents" => 110}
             )

    assert report(conn, "2027-10-05")["credit"] == credit(110, %{"expired_cents" => 30}, 80)
    applied(conn, [close("2026-10-05"), op("cancel_group", "target")])
    assert report(conn, "2026-10-06")["late_adjustments"] == adjustments()
    assert report(conn, "2027-10-05")["credit"] == credit(110, %{"expired_cents" => 110}, 0)
    assert report(conn, "2027-10-05")["late_adjustments"] == adjustments()
    reconcile(conn, "2027-10-05")
  end

  test "late shortfall absorption and nonrefundable consumption reduce applied liability", %{
    conn: conn
  } do
    applied(
      conn,
      [start()] ++
        issue("issuer", 100) ++
        [
          opening("restore", "p"),
          opening("consume", "p", %{"rate_plan" => "advance_purchase"}),
          op("apply_hotel_credit", "restore", %{"amount_cents" => 60}),
          op("apply_hotel_credit", "consume", %{"amount_cents" => 50}),
          correction("charge_back_payment", "issuer-pay"),
          close("2027-10-05")
        ]
    )

    frozen = published(conn, ~w(2026-10-04 2027-10-05))
    applied(conn, [op("cancel_group", "restore"), op("cancel_group", "consume")])
    assert report(conn, "2027-10-06")["credit"] == credit(110, %{}, 0)

    assert report(conn, "2027-10-06")["late_adjustments"] ==
             adjustments([], %{"absorbed_cents" => 60, "consumed_cents" => 50})

    assert published(conn, Map.keys(frozen)) == frozen
    assert Reservations.ledger(~D[2027-10-06]).credit_shortfall_cents == 0
    reconcile(conn, "2027-10-06")
  end

  test "late issuance past expiry posts both issuance and expiry on the first open day", %{
    conn: conn
  } do
    applied(conn, [start(), close("2027-10-05")] ++ issue("issuer", 100))
    assert report(conn, "2027-10-05")["credit"] == credit(0, %{}, 0)
    assert report(conn, "2027-10-06")["credit"] == credit(0, %{}, 0)

    assert report(conn, "2027-10-06")["late_adjustments"] ==
             adjustments(
               [
                 late_cash("issuer", %{
                   "received_cents" => 100,
                   "converted_to_credit_cents" => 100
                 })
               ],
               %{"issued_cents" => 110, "expired_cents" => 110}
             )

    reconcile(conn, "2027-10-06")
  end

  test "closing through the last ISO date preserves reports and later domain operations", %{
    conn: conn
  } do
    applied(conn, [
      start(),
      opening("g", "p"),
      pay("p", "g", 100),
      close("9999-12-31")
    ])

    frozen = published(conn, ~w(2026-10-04 9999-12-30 9999-12-31))
    [result] = applied(conn, [pay("after-last-date", "g", 50)])
    assert result["revision"] == 3
    assert Reservations.get_group("g").cash_paid_cents == 150
    assert published(conn, Map.keys(frozen)) == frozen

    assert %{posted_on: on, late_adjustment: true} =
             Repo.get_by(GroupStay.FinanceReporting.Movement, operation_id: "after-last-date")

    assert on == Date.add(~D[9999-12-31], 1)
  end

  defp start,
    do: %{
      "operation_id" => Ecto.UUID.generate(),
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-04"
    }

  defp close(on),
    do: %{
      "operation_id" => Ecto.UUID.generate(),
      "type" => "close_finance_period",
      "period_end_on" => on
    }

  defp opening(id, property, attrs \\ %{}),
    do:
      open_operation(
        Map.merge(
          %{
            "group_id" => id,
            "property_id" => property,
            "arrival_on" => "2028-12-10",
            "departure_on" => "2028-12-13"
          },
          attrs
        )
      )

  defp op(type, group, attrs \\ %{}), do: operation(type, Map.put(attrs, "group_id", group))

  defp pay(id, group, amount, on \\ "2026-10-04"),
    do:
      op("record_cash_payment", group, %{
        "operation_id" => id,
        "amount_cents" => amount,
        "occurred_on" => on
      })

  defp correction(type, payment, attrs \\ %{}),
    do: operation(type, Map.put(attrs, "payment_operation_id", payment)) |> Map.delete("group_id")

  defp transfer(source, destination, amount),
    do:
      op("transfer_deposit", nil, %{
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  defp issue(id, amount),
    do: [
      opening(id, "issuer"),
      pay(id <> "-pay", id, amount),
      op("cancel_group", id, %{"refund_method" => "hotel_credit"})
    ]

  defp fields(names, values), do: Map.merge(Map.new(names, &{&1, 0}), values)

  defp cash(property, opening, movements, closing),
    do: %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" => fields(@cash_fields, movements),
      "closing_held_cents" => closing
    }

  defp credit(opening, movements, closing),
    do: %{
      "opening_liability_cents" => opening,
      "movements" => fields(@credit_fields, movements),
      "closing_liability_cents" => closing
    }

  defp late_cash(property, movements),
    do: %{"property_id" => property, "movements" => fields(@cash_fields, movements)}

  defp adjustments(cash \\ [], credit \\ %{}),
    do: %{"cash" => cash, "credit" => fields(@credit_fields, credit)}

  defp batch(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp applied(conn, operations) do
    results = batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp report(conn, on) do
    data =
      conn
      |> get("/api/v1/finance/daily-report", %{"date" => on})
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.sort(Map.keys(data)) == ~w(cash credit date late_adjustments status)
    assert Enum.sort(Map.keys(data["late_adjustments"])) == ~w(cash credit)
    late = Map.new(data["late_adjustments"]["cash"], &{&1["property_id"], &1["movements"]})

    assert Enum.map(data["cash"], & &1["property_id"]) ==
             Enum.sort(Enum.map(data["cash"], & &1["property_id"]))

    assert Enum.map(data["late_adjustments"]["cash"], & &1["property_id"]) ==
             Enum.sort(Map.keys(late))

    for row <- data["late_adjustments"]["cash"] do
      assert Enum.sort(Map.keys(row)) == ~w(movements property_id)
      assert Enum.sort(Map.keys(row["movements"])) == Enum.sort(@cash_fields)
      assert Enum.any?(row["movements"], fn {_, amount} -> amount != 0 end)
    end

    for row <- data["cash"] do
      m =
        Map.merge(row["movements"], Map.get(late, row["property_id"], %{}), fn _, a, b ->
          a + b
        end)

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end

    assert Enum.sort(Map.keys(data["late_adjustments"]["credit"])) == Enum.sort(@credit_fields)

    m =
      Map.merge(data["credit"]["movements"], data["late_adjustments"]["credit"], fn _, a, b ->
        a + b
      end)

    assert data["credit"]["closing_liability_cents"] ==
             data["credit"]["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    data
  end

  defp published(conn, dates) do
    before = snapshot()

    reports =
      Map.new(dates, fn on ->
        data = report(conn, on)
        assert data["status"] == "closed"
        {on, Jason.encode!(data)}
      end)

    assert snapshot() == before
    reports
  end

  defp reconcile(conn, on) do
    data = report(conn, on)
    ledger = Reservations.ledger(Date.from_iso8601!(on))
    assert Enum.sum(Enum.map(data["cash"], & &1["closing_held_cents"])) == ledger.cash_held_cents
    assert data["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end

  defp snapshot do
    for table <-
          ~w(groups room_allocations credit_lots credit_allocations credit_entitlements finance_reporting finance_movements),
        do: Repo.query!("SELECT * FROM #{table} ORDER BY 1").rows
  end
end
