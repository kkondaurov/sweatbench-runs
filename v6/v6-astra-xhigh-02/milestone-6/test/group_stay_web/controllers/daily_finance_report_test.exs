defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false
  import GroupStay.ReservationFixtures
  alias GroupStay.{Repo, Reservations}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  test "report date is required and validated before availability", %{conn: conn} do
    for params <- [
          %{},
          %{"date" => ""},
          %{"date" => "2026-02-30"},
          %{"date" => "2026-1-01"},
          %{"date" => ["2026-10-04"]},
          %{"date" => %{"day" => "2026-10-04"}}
        ] do
      assert conn |> get("/api/v1/finance/daily-report", params) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    unavailable(conn, "2026-10-04")
    applied(conn, [start()])
    unavailable(conn, "2026-10-03")
    assert report(conn, "2026-10-04") == expected_report("2026-10-04", [])
    assert report(conn, "2029-01-01") == expected_report("2029-01-01", [])
  end

  test "start validates its own date, has no group or revision, and is durably replayed", %{
    conn: conn
  } do
    invalid =
      for value <- [nil, "", "2026-02-29", "2026-10-04T00:00:00Z", 123, true, [], %{}],
          do: Map.put(start(), "starts_on", value)

    invalid = [Map.delete(start(), "starts_on") | invalid]
    results = batch(conn, invalid)
    assert Enum.all?(results, &(&1["code"] == "invalid_reporting_date"))
    unavailable(conn, "2026-10-04")
    applied(conn, [opening("g", "p")])

    start = Map.merge(start(), %{"group_id" => "missing", "expected_revision" => -1})
    [result] = applied(conn, [start])

    assert result == %{
             "operation_id" => start["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-10-04"
           }

    assert Reservations.get_group("g").revision == 1
    assert batch(conn, [start]) == [result]

    assert conn |> get("/api/v1/operations/#{start["operation_id"]}") |> json_response(200) == %{
             "data" => result
           }

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(start, "starts_on", "2026-10-05")])

    assert [%{"code" => "reporting_already_started"}] = batch(conn, [start()])
    assert batch(conn, invalid) == results
  end

  test "inception follows commit order within a batch and clamps subsequent posting dates", %{
    conn: conn
  } do
    operations = [
      opening("g", "p"),
      pay("before", "g", 100, "2028-01-01"),
      start(),
      pay("after", "g", 50, "2026-01-01"),
      pay("later", "g", 25, "2026-10-06")
    ]

    originals = applied(conn, operations)

    assert report(conn, "2026-10-04") ==
             expected_report("2026-10-04", [cash("p", 100, %{"received_cents" => 50}, 150)])

    assert report(conn, "2026-10-05") == expected_report("2026-10-05", [cash("p", 150, %{}, 150)])

    assert report(conn, "2026-10-06") ==
             expected_report("2026-10-06", [cash("p", 150, %{"received_cents" => 25}, 175)])

    before = snapshot()
    assert batch(conn, operations) == originals
    assert snapshot() == before
    applied(conn, [pay("late-submission", "g", 10, "2026-10-04")])

    assert report(conn, "2026-10-04") ==
             expected_report("2026-10-04", [cash("p", 100, %{"received_cents" => 60}, 160)])

    assert report(conn, "2026-10-06")["cash"] == [cash("p", 160, %{"received_cents" => 25}, 185)]
    reconcile(conn, "2026-10-06")
  end

  test "cash columns follow transfers and every disposition back to its settlement property", %{
    conn: conn
  } do
    applied(conn, [
      start(),
      opening("source", "z"),
      opening("refund", "a"),
      opening("retain", "a", %{"rate_plan" => "advance_purchase"}),
      opening("convert", "b"),
      opening("held", "c"),
      opening("empty", "unused"),
      pay("p", "source", 1000, "2026-10-04"),
      transfer("source", "refund", 200, "2026-10-05"),
      transfer("source", "retain", 150, "2026-10-05"),
      transfer("source", "convert", 100, "2026-10-05"),
      transfer("source", "held", 250, "2026-10-05"),
      op("cancel_group", "refund", "2026-10-06"),
      op("cancel_group", "retain", "2026-10-06"),
      op("cancel_group", "convert", "2026-10-06", %{"refund_method" => "hotel_credit"}),
      correction("reduce_cash_payment", "p", "2026-10-07", %{"amount_cents" => 50})
    ])

    assert report(conn, "2026-10-05")["cash"] == [
             cash("a", 0, %{"transferred_in_cents" => 350}, 350),
             cash("b", 0, %{"transferred_in_cents" => 100}, 100),
             cash("c", 0, %{"transferred_in_cents" => 250}, 250),
             cash("z", 1000, %{"transferred_out_cents" => 700}, 300)
           ]

    assert report(conn, "2026-10-06")["cash"] == [
             cash("a", 350, %{"refunded_cents" => 200, "retained_cents" => 150}, 0),
             cash("b", 100, %{"converted_to_credit_cents" => 100}, 0),
             cash("c", 250, %{}, 250),
             cash("z", 300, %{}, 300)
           ]

    assert report(conn, "2026-10-06")["credit"] == credit(0, %{"issued_cents" => 110}, 110)

    assert report(conn, "2026-10-07")["cash"] == [
             cash("c", 250, %{"reduced_cents" => 50}, 200),
             cash("z", 300, %{}, 300)
           ]

    chargeback = correction("charge_back_payment", "p", "2026-10-08")
    [result] = applied(conn, [chargeback])
    assert result["charged_back_cents"] == 950

    expected =
      expected_report(
        "2026-10-08",
        [
          cash(
            "a",
            0,
            %{"refunded_cents" => -200, "retained_cents" => -150, "charged_back_cents" => 350},
            0
          ),
          cash("b", 0, %{"converted_to_credit_cents" => -100, "charged_back_cents" => 100}, 0),
          cash("c", 200, %{"charged_back_cents" => 200}, 0),
          cash("z", 300, %{"charged_back_cents" => 300}, 0)
        ],
        credit(110, %{"revoked_cents" => 110}, 0)
      )

    assert report(conn, "2026-10-08") == expected
    assert batch(conn, [chargeback]) == [result]
    assert report(conn, "2026-10-08") == expected
    assert report(conn, "2026-10-09")["cash"] == []
    reconcile(conn, "2026-10-08")
  end

  test "same-property transfers record both directions and mixed funding transfers count only cash",
       %{conn: conn} do
    applied(
      conn,
      issue("issuer", 100) ++
        [
          opening("s", "same"),
          opening("d", "same"),
          pay("p", "s", 100, "2026-10-04"),
          op("apply_hotel_credit", "s", "2026-10-04", %{"amount_cents" => 110}),
          start(),
          transfer("s", "d", 150, "2026-10-04")
        ]
    )

    assert report(conn, "2026-10-04") ==
             expected_report(
               "2026-10-04",
               [
                 cash(
                   "same",
                   100,
                   %{"transferred_in_cents" => 40, "transferred_out_cents" => 40},
                   100
                 )
               ],
               credit(110, %{}, 110)
             )

    applied(conn, [transfer("d", "s", 30, "2026-10-05")])
    assert report(conn, "2026-10-05")["credit"] == credit(110, %{}, 110)
    reconcile(conn, "2026-10-05")
  end

  test "unused credit expires on the following date while applied credit has paused expiry", %{
    conn: conn
  } do
    applied(
      conn,
      [start()] ++
        issue("issuer", 100) ++
        [
          opening("target", "p"),
          op("apply_hotel_credit", "target", "2026-10-05", %{"amount_cents" => 80})
        ]
    )

    assert report(conn, "2026-10-04")["credit"] == credit(0, %{"issued_cents" => 110}, 110)
    assert report(conn, "2026-10-05")["credit"] == credit(110, %{}, 110)
    assert report(conn, "2027-10-04")["credit"] == credit(110, %{}, 110)
    assert report(conn, "2027-10-05")["credit"] == credit(110, %{"expired_cents" => 30}, 80)
    assert report(conn, "2027-10-06")["credit"] == credit(80, %{}, 80)
    before = snapshot()
    for date <- ~w(2027-10-06 2026-10-04 2027-10-05 2027-10-04 2027-10-05), do: report(conn, date)
    assert snapshot() == before
    reconcile(conn, "2027-10-05")

    applied(conn, [op("cancel_group", "target", "2027-10-06")])
    assert report(conn, "2027-10-06")["credit"] == credit(80, %{"expired_cents" => 80}, 0)
    reconcile(conn, "2027-10-06")
  end

  test "inception includes available and applied credit but omits already expired liability", %{
    conn: conn
  } do
    applied(
      conn,
      issue("old", 100, "2025-10-04") ++
        issue("new", 200) ++
        [
          opening("target", "p"),
          op("apply_hotel_credit", "target", "2025-10-04", %{"amount_cents" => 80}),
          start("2026-10-05")
        ]
    )

    assert report(conn, "2026-10-05")["credit"] == credit(300, %{}, 300)
    assert report(conn, "2027-10-05")["credit"] == credit(300, %{"expired_cents" => 220}, 80)
    reconcile(conn, "2027-10-05")
  end

  test "refundable restorations preserve expiry and consumption removes applied liability", %{
    conn: conn
  } do
    applied(
      conn,
      [start()] ++
        issue("issuer", 100) ++
        [
          opening("restore", "p"),
          opening("consume", "p", %{"rate_plan" => "advance_purchase"}),
          op("apply_hotel_credit", "restore", "2026-10-05", %{"amount_cents" => 60}),
          op("apply_hotel_credit", "consume", "2026-10-05", %{"amount_cents" => 50}),
          op("cancel_group", "restore", "2026-10-06"),
          op("cancel_group", "consume", "2026-10-07")
        ]
    )

    assert report(conn, "2026-10-06")["credit"] == credit(110, %{}, 110)
    assert report(conn, "2026-10-07")["credit"] == credit(110, %{"consumed_cents" => 50}, 60)
    assert report(conn, "2027-10-05")["credit"] == credit(60, %{"expired_cents" => 60}, 0)
    reconcile(conn, "2027-10-05")
  end

  test "clawback revokes available credit and restoration absorbs shortfall before expiry", %{
    conn: conn
  } do
    applied(
      conn,
      [start()] ++
        issue("issuer", 100) ++
        [
          opening("target", "p"),
          op("apply_hotel_credit", "target", "2026-10-05", %{"amount_cents" => 80}),
          correction("charge_back_payment", "issuer-pay", "2026-10-06")
        ]
    )

    assert report(conn, "2026-10-06")["credit"] == credit(110, %{"revoked_cents" => 30}, 80)
    assert report(conn, "2027-10-05")["credit"] == credit(80, %{}, 80)
    assert Reservations.ledger(~D[2027-10-05]).credit_shortfall_cents == 80
    applied(conn, [op("cancel_group", "target", "2027-10-06")])
    assert report(conn, "2027-10-06")["credit"] == credit(80, %{"absorbed_cents" => 80}, 0)
    reconcile(conn, "2027-10-06")
  end

  test "chargeback after unused credit has expired does not revoke liability a second time", %{
    conn: conn
  } do
    applied(
      conn,
      [start()] ++
        issue("issuer", 100) ++
        [
          correction("charge_back_payment", "issuer-pay", "2027-10-06")
        ]
    )

    assert report(conn, "2027-10-05")["credit"] == credit(110, %{"expired_cents" => 110}, 0)
    assert report(conn, "2027-10-06")["credit"] == credit(0, %{}, 0)
    reconcile(conn, "2027-10-06")
  end

  test "late backdated redemptions revise an already read expiry day without read side effects",
       %{conn: conn} do
    applied(conn, [start()] ++ issue("issuer", 100) ++ [opening("target", "p")])
    assert report(conn, "2027-10-05")["credit"] == credit(110, %{"expired_cents" => 110}, 0)
    applied(conn, [op("apply_hotel_credit", "target", "2027-10-04", %{"amount_cents" => 80})])
    assert report(conn, "2027-10-05")["credit"] == credit(110, %{"expired_cents" => 30}, 80)
    reconcile(conn, "2027-10-05")
  end

  test "clamping a backdated credit application or issuance past expiry reconciles liability", %{
    conn: conn
  } do
    applied(conn, issue("old", 100) ++ [opening("target", "p"), start("2027-10-06")])
    assert report(conn, "2027-10-06")["credit"] == credit(0, %{}, 0)

    applied(
      conn,
      [op("apply_hotel_credit", "target", "2026-10-04", %{"amount_cents" => 80})] ++
        issue("late", 50)
    )

    assert report(conn, "2027-10-06")["credit"] ==
             credit(0, %{"issued_cents" => 55, "expired_cents" => -25}, 80)

    reconcile(conn, "2027-10-06")
  end

  test "room cancellation rounds issuance once across the selected rooms", %{
    conn: conn
  } do
    rooms = for id <- ~w(a b c), do: %{"room_id" => id, "nightly_rate_cents" => 10}

    applied(conn, [
      start(),
      opening("g", "p", %{"rooms" => rooms, "departure_on" => "2028-12-11"}),
      pay("p", "g", 6, "2026-10-04"),
      op("cancel_rooms", "g", "2026-10-05", %{
        "room_ids" => ["c", "a", "b"],
        "refund_method" => "hotel_credit"
      })
    ])

    assert report(conn, "2026-10-05")["credit"] == credit(0, %{"issued_cents" => 7}, 7)

    assert report(conn, "2026-10-05")["cash"] == [
             cash("p", 6, %{"converted_to_credit_cents" => 6}, 0)
           ]
  end

  test "rejected operations and retries have no movement and later batch entries still apply", %{
    conn: conn
  } do
    bad = pay("bad", "g", -10, "2026-10-04")
    good = pay("good", "g", 100, "2026-10-04")

    results =
      batch(conn, [
        start(),
        opening("g", "p"),
        bad,
        good,
        bad,
        good,
        Map.put(good, "amount_cents", 200),
        op("cancel_group", "g", "2026-10-05", %{"expected_revision" => 1})
      ])

    assert Enum.map(results, & &1["status"]) ==
             ~w(applied applied rejected applied rejected applied rejected rejected)

    assert report(conn, "2026-10-04")["cash"] == [cash("p", 0, %{"received_cents" => 100}, 100)]
    assert report(conn, "2026-10-05")["cash"] == [cash("p", 100, %{}, 100)]
  end

  test "rounded payment entitlements split restoration into shortfall absorption and expiry", %{
    conn: conn
  } do
    applied(conn, [
      start(),
      opening("issuer", "p"),
      pay("first", "issuer", 4, "2026-10-04"),
      pay("second", "issuer", 1, "2026-10-04"),
      op("cancel_group", "issuer", "2026-10-04", %{"refund_method" => "hotel_credit"}),
      opening("target", "p"),
      op("apply_hotel_credit", "target", "2026-10-05", %{"amount_cents" => 5}),
      correction("charge_back_payment", "first", "2026-10-06"),
      op("cancel_group", "target", "2027-10-06")
    ])

    assert report(conn, "2026-10-04")["credit"] == credit(0, %{"issued_cents" => 6}, 6)
    assert report(conn, "2026-10-06")["credit"] == credit(6, %{"revoked_cents" => 1}, 5)
    assert report(conn, "2027-10-05")["credit"] == credit(5, %{}, 5)

    assert report(conn, "2027-10-06")["credit"] ==
             credit(5, %{"absorbed_cents" => 3, "expired_cents" => 2}, 0)

    reconcile(conn, "2027-10-06")
  end

  test "nonrefundable consumption extinguishes applied shortfall without an absorption movement",
       %{conn: conn} do
    applied(
      conn,
      [start()] ++
        issue("issuer", 100) ++
        [
          opening("target", "p", %{"rate_plan" => "advance_purchase"}),
          op("apply_hotel_credit", "target", "2026-10-05", %{"amount_cents" => 110}),
          correction("charge_back_payment", "issuer-pay", "2026-10-06"),
          op("cancel_group", "target", "2026-10-07")
        ]
    )

    assert report(conn, "2026-10-06")["credit"] == credit(110, %{}, 110)
    assert report(conn, "2026-10-07")["credit"] == credit(110, %{"consumed_cents" => 110}, 0)
    assert Reservations.ledger(~D[2026-10-07]).credit_shortfall_cents == 0
    reconcile(conn, "2026-10-07")
  end

  test "property totals and persisted opening remain exact beyond SQLite's integer range", %{
    conn: conn
  } do
    amount = 9_223_372_036_854_775_807

    bookings =
      for id <- ~w(a b),
          op <- [
            opening(id, "p", %{
              "rate_plan" => "advance_purchase",
              "departure_on" => "2028-12-11",
              "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => amount}]
            }),
            pay(id, id, amount, "2026-10-04")
          ],
          do: op

    applied(
      conn,
      bookings ++
        [
          start(),
          correction("charge_back_payment", "a", "2026-10-05"),
          pay("replacement", "a", amount, "2026-10-05")
        ]
    )

    assert report(conn, "2026-10-04")["cash"] == [cash("p", amount * 2, %{}, amount * 2)]

    assert report(conn, "2026-10-05")["cash"] == [
             cash(
               "p",
               amount * 2,
               %{"charged_back_cents" => amount, "received_cents" => amount},
               amount * 2
             )
           ]

    reconcile(conn, "2026-10-05")
  end

  test "a lot valid through the last supported ISO date still issues and remains readable", %{
    conn: conn
  } do
    applied(conn, [
      start("9998-12-31"),
      opening("g", "p", %{"arrival_on" => "9999-12-20", "departure_on" => "9999-12-21"}),
      pay("p", "g", 100, "9998-12-31"),
      op("cancel_group", "g", "9998-12-31", %{"refund_method" => "hotel_credit"})
    ])

    assert report(conn, "9998-12-31")["credit"] == credit(0, %{"issued_cents" => 110}, 110)
    assert report(conn, "9999-12-31")["credit"] == credit(110, %{}, 110)
    reconcile(conn, "9999-12-31")
  end

  test "pre-inception settlements can be corrected and pre-inception shortfall can be absorbed",
       %{conn: conn} do
    applied(
      conn,
      issue("issuer", 100) ++
        [
          opening("target", "p"),
          op("apply_hotel_credit", "target", "2026-10-04", %{"amount_cents" => 80}),
          correction("charge_back_payment", "issuer-pay", "2026-10-04"),
          opening("refunded", "history"),
          pay("refund-pay", "refunded", 50, "2026-10-04"),
          op("cancel_group", "refunded", "2026-10-04"),
          start(),
          correction("charge_back_payment", "refund-pay", "2026-10-05"),
          op("cancel_group", "target", "2026-10-05")
        ]
    )

    assert report(conn, "2026-10-04") == expected_report("2026-10-04", [], credit(80, %{}, 80))

    assert report(conn, "2026-10-05") ==
             expected_report(
               "2026-10-05",
               [
                 cash("history", 0, %{"refunded_cents" => -50, "charged_back_cents" => 50}, 0)
               ],
               credit(80, %{"absorbed_cents" => 80}, 0)
             )

    reconcile(conn, "2026-10-05")
  end

  test "reporting preserves domain validation for malformed financial identifiers", %{conn: conn} do
    applied(conn, [start()])

    malformed =
      for value <- [nil, true, 1, [], %{}],
          op <- [
            op("record_cash_payment", value, "2026-10-04", %{"amount_cents" => 1}),
            transfer(value, "missing", 1, "2026-10-04"),
            correction("charge_back_payment", value, "2026-10-04")
          ],
          do: op

    assert Enum.all?(batch(conn, malformed), &(&1["code"] == "invalid_operation"))
    assert report(conn, "2026-10-04") == expected_report("2026-10-04", [])
  end

  defp start(on \\ "2026-10-04"),
    do: %{
      "operation_id" => "start-#{Ecto.UUID.generate()}",
      "type" => "start_finance_reporting",
      "starts_on" => on
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

  defp op(type, group, on, attrs \\ %{}),
    do: operation(type, Map.merge(%{"group_id" => group, "occurred_on" => on}, attrs))

  defp pay(id, group, amount, on),
    do: op("record_cash_payment", group, on, %{"operation_id" => id, "amount_cents" => amount})

  defp correction(type, payment, on, attrs \\ %{}),
    do:
      op(type, nil, on, Map.put(attrs, "payment_operation_id", payment)) |> Map.delete("group_id")

  defp transfer(source, destination, amount, on),
    do:
      op("transfer_deposit", nil, on, %{
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      })
      |> Map.delete("group_id")

  defp issue(id, amount, on \\ "2026-10-04"),
    do: [
      opening(id, "issuer"),
      pay(id <> "-pay", id, amount, on),
      op("cancel_group", id, on, %{"refund_method" => "hotel_credit"})
    ]

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

  defp report(conn, date) do
    report =
      conn
      |> get("/api/v1/finance/daily-report", %{"date" => date})
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.sort(Map.keys(report)) == ~w(cash credit date status)
    assert report["date"] == date
    assert report["status"] == "open"

    assert Enum.map(report["cash"], & &1["property_id"]) ==
             Enum.sort(Enum.map(report["cash"], & &1["property_id"]))

    for row <- report["cash"] do
      assert Enum.sort(Map.keys(row)) ==
               ~w(closing_held_cents movements opening_held_cents property_id)

      assert Enum.sort(Map.keys(row["movements"])) == Enum.sort(@cash_fields)
      m = row["movements"]

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end

    assert Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))

    c = report["credit"]
    assert Enum.sort(Map.keys(c)) == ~w(closing_liability_cents movements opening_liability_cents)
    assert Enum.sort(Map.keys(c["movements"])) == Enum.sort(@credit_fields)
    m = c["movements"]

    assert c["closing_liability_cents"] ==
             c["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    report
  end

  defp unavailable(conn, date),
    do:
      assert(
        conn |> get("/api/v1/finance/daily-report", %{"date" => date}) |> json_response(404) == %{
          "error" => %{"code" => "report_not_available"}
        }
      )

  defp cash(property, opening, movements, closing),
    do: %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" => Map.merge(Map.new(@cash_fields, &{&1, 0}), movements),
      "closing_held_cents" => closing
    }

  defp credit(opening, movements, closing),
    do: %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(Map.new(@credit_fields, &{&1, 0}), movements),
      "closing_liability_cents" => closing
    }

  defp expected_report(date, cash, credit \\ credit(0, %{}, 0)),
    do: %{"date" => date, "status" => "open", "cash" => cash, "credit" => credit}

  defp reconcile(conn, on) do
    report = report(conn, on)
    ledger = Reservations.ledger(Date.from_iso8601!(on))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end

  defp snapshot do
    for table <-
          ~w(groups room_allocations credit_lots credit_allocations credit_entitlements partner_operations finance_reporting finance_movements),
        do: Repo.query!("SELECT * FROM #{table} ORDER BY 1").rows
  end
end
