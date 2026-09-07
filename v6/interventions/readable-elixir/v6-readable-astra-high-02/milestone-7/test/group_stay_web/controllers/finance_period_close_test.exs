defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.FinanceReporting.{Movement, PeriodClose}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents
                  retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  test "close validation and exact durable results, including remembered rejections", %{
    conn: conn
  } do
    premature = close("2026-11-01")
    assert [rejected = %{"code" => "invalid_period"}] = batch(conn, [premature])
    batch(conn, [start()])
    assert batch(conn, [premature]) == [rejected]

    for value <- [nil, "", "bad", "2026-02-30", 123, [], %{}, "2026-10-31"] do
      assert [%{"code" => "invalid_period"}] = batch(conn, [close(value)])
    end

    assert [%{"code" => "invalid_period"}] =
             batch(conn, [Map.delete(close("2026-11-01"), "period_end_on")])

    assert Repo.all(PeriodClose) == []
    assert Repo.all(Movement) == []

    close = close("2026-11-01") |> Map.put("expected_revision", "ignored")
    assert [result] = batch(conn, [close])

    assert result == %{
             "operation_id" => close["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-11-01"
           }

    assert batch(conn, [close]) == [result]

    assert conn |> get("/api/v1/operations/#{close["operation_id"]}") |> json_response(200) ==
             %{"data" => result}

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(close, "period_end_on", "2026-11-02")])

    for date <- ["2026-11-01", "2026-10-31"] do
      assert [%{"code" => "invalid_period"}] = batch(conn, [close(date)])
    end

    assert [%{"status" => "applied"}] = batch(conn, [close("2026-11-03")])
    assert batch(conn, [close]) == [result]
    assert Repo.aggregate(PeriodClose, :count) == 2

    for date <- ["2026-11-01", "2026-11-02", "2026-11-03"] do
      assert report(conn, date) == %{
               "date" => date,
               "status" => "closed",
               "cash" => [],
               "credit" => credit_row(0, %{}, 0),
               "late_adjustments" => late([], %{})
             }
    end

    assert report(conn, "2026-11-04")["status"] == "open"

    assert conn |> get("/api/v1/finance/daily-report?date=2026-10-31") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}
  end

  test "same-batch closes freeze reports and posting dates while open dates stay ordinary", %{
    conn: conn
  } do
    early = payment(100, "2026-10-01")
    late_payment = payment(40, "2026-10-01")

    operations = [
      booking(),
      start(),
      early,
      close("2026-11-02"),
      late_payment,
      payment(10, "2026-11-03"),
      payment(20, "2026-11-05"),
      close("2026-11-03"),
      payment(30, "2026-11-01")
    ]

    dates = ~w(2026-11-01 2026-11-02 2026-11-03 2026-11-04 2026-11-05)

    {:error, expected} =
      Repo.transaction(fn ->
        batch(conn, operations)
        Repo.rollback(Enum.map(dates, &report(conn, &1)))
      end)

    results = Enum.flat_map(operations, &batch(conn, [&1]))
    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert Enum.map(dates, &report(conn, &1)) == expected

    [first, second, third, fourth, fifth] = expected
    assert first["cash"] == [cash_row("ams-canal", 0, %{"received_cents" => 100}, 100)]
    assert first["late_adjustments"] == late([], %{})
    assert second["cash"] == [cash_row("ams-canal", 100, %{}, 100)]
    assert third["cash"] == [cash_row("ams-canal", 100, %{"received_cents" => 10}, 150)]
    assert third["late_adjustments"] == late([{"ams-canal", %{"received_cents" => 40}}], %{})
    assert fourth["cash"] == [cash_row("ams-canal", 150, %{}, 180)]
    assert fourth["late_adjustments"] == late([{"ams-canal", %{"received_cents" => 30}}], %{})
    assert fifth["cash"] == [cash_row("ams-canal", 180, %{"received_cents" => 20}, 200)]
    assert fifth["late_adjustments"] == late([], %{})

    closed_bytes = Enum.map(Enum.take(dates, 3), &report_bytes(conn, &1))
    before = Repo.all(Movement)
    assert batch(conn, [early, late_payment]) == [Enum.at(results, 2), Enum.at(results, 4)]
    assert Repo.all(Movement) == before

    batch(conn, [
      close("2026-11-06"),
      operation("reduce_cash_payment", %{
        "payment_operation_id" => early["operation_id"],
        "amount_cents" => 50
      })
    ])

    assert Enum.map(Enum.take(dates, 3), &report_bytes(conn, &1)) == closed_bytes

    assert report(conn, "2026-11-07")["late_adjustments"] ==
             late([{"ams-canal", %{"reduced_cents" => 50}}], %{})

    assert_reconciled(conn, "2026-11-07")

    assert {:ok, %{recorded_cents: 100, held_cents: 50, reduced_cents: 50}} =
             Reservations.get_payment(early["operation_id"])
  end

  test "late transfers and chargebacks retain signed classifications at every affected property",
       %{
         conn: conn
       } do
    payment = payment(400)

    batch(conn, [
      start(),
      booking(),
      booking("refund", "a-refund"),
      booking("convert", "b-convert"),
      booking("retain", "c-retain") |> Map.put("rate_plan", "advance_purchase"),
      payment,
      close("2026-11-01"),
      transfer("refund", 100),
      transfer("convert", 100),
      transfer("retain", 100),
      cancel("refund"),
      cancel("convert", %{"refund_method" => "hotel_credit"}),
      cancel("retain"),
      close("2026-11-02")
    ])

    day = report(conn, "2026-11-02")

    assert day["late_adjustments"] ==
             late(
               [
                 {"a-refund", %{"transferred_in_cents" => 100, "refunded_cents" => 100}},
                 {"ams-canal", %{"transferred_out_cents" => 300}},
                 {"b-convert",
                  %{"transferred_in_cents" => 100, "converted_to_credit_cents" => 100}},
                 {"c-retain", %{"transferred_in_cents" => 100, "retained_cents" => 100}}
               ],
               %{"issued_cents" => 110}
             )

    batch(conn, [
      operation("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]})
    ])

    charge = report(conn, "2026-11-03")

    assert charge["late_adjustments"] ==
             late(
               [
                 {"a-refund", %{"refunded_cents" => -100, "charged_back_cents" => 100}},
                 {"ams-canal", %{"charged_back_cents" => 100}},
                 {"b-convert",
                  %{"converted_to_credit_cents" => -100, "charged_back_cents" => 100}},
                 {"c-retain", %{"retained_cents" => -100, "charged_back_cents" => 100}}
               ],
               %{"revoked_cents" => 110}
             )

    assert charge["cash"] == [
             cash_row("a-refund", 0, %{}, 0),
             cash_row("ams-canal", 100, %{}, 0),
             cash_row("b-convert", 0, %{}, 0),
             cash_row("c-retain", 0, %{}, 0)
           ]

    assert charge["credit"] == credit_row(110, %{}, 0)
    assert report(conn, "2026-11-02") == day
    assert_reconciled(conn, "2026-11-03")
    assert report(conn, "2027-11-02")["credit"] == credit_row(0, %{}, 0)
    assert report(conn, "2027-11-02")["late_adjustments"] == late([], %{})
  end

  test "closed expiry stays published when backdated credit is applied and restored", %{
    conn: conn
  } do
    batch(conn, [
      start(),
      booking(),
      payment(100),
      cancel("group-81", %{"refund_method" => "hotel_credit"}),
      booking("target", "target"),
      close("2027-11-02")
    ])

    expiry = report_bytes(conn, "2027-11-02")
    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)

    batch(conn, [
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80})
    ])

    assert report_bytes(conn, "2027-11-02") == expiry
    assert report(conn, "2027-11-03")["credit"] == credit_row(0, %{}, 80)
    assert report(conn, "2027-11-03")["late_adjustments"] == late([], %{"expired_cents" => -80})
    assert_reconciled(conn, "2027-11-03")

    batch(conn, [close("2027-11-03")])
    applied_day = report_bytes(conn, "2027-11-03")
    batch(conn, [cancel("target")])
    assert report(conn, "2027-11-04")["credit"] == credit_row(80, %{}, 0)
    assert report(conn, "2027-11-04")["late_adjustments"] == late([], %{"expired_cents" => 80})
    assert report_bytes(conn, "2027-11-02") == expiry
    assert report_bytes(conn, "2027-11-03") == applied_day
    assert_reconciled(conn, "2027-11-04")
  end

  test "future expiry remains ordinary for late issuance and future schedule changes", %{
    conn: conn
  } do
    batch(conn, [
      start(),
      booking(),
      payment(100),
      close("2026-11-01"),
      cancel("group-81", %{"refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2026-11-02")["credit"] == credit_row(0, %{}, 110)

    assert report(conn, "2026-11-02")["late_adjustments"]["credit"] ==
             fields(@credit_fields, %{"issued_cents" => 110})

    batch(conn, [
      booking("target", "target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80}),
      cancel("target", %{"occurred_on" => "2026-11-03"})
    ])

    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)
    assert report(conn, "2027-11-02")["late_adjustments"] == late([], %{})
    batch(conn, [close("2027-11-02")])
    expiry = report_bytes(conn, "2027-11-02")
    before = Repo.all(Movement)
    rejected = payment(1)
    assert [result = %{"code" => "group_not_active"}] = batch(conn, [rejected])
    assert batch(conn, [rejected]) == [result]
    assert Repo.all(Movement) == before
    assert report_bytes(conn, "2027-11-02") == expiry
    assert_reconciled(conn, "2027-11-03")
  end

  test "expiry on the first open day stays ordinary even for a late credit application", %{
    conn: conn
  } do
    batch(conn, [
      start(),
      booking(),
      payment(100),
      cancel("group-81", %{"refund_method" => "hotel_credit"}),
      booking("target", "target"),
      close("2027-11-01"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80})
    ])

    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 30}, 80)
    assert report(conn, "2027-11-02")["late_adjustments"] == late([], %{})
    assert_reconciled(conn, "2027-11-02")
  end

  test "late issuance of already expired credit reports both issuance and expiry", %{conn: conn} do
    batch(conn, [
      start(),
      booking(),
      payment(100),
      close("2027-11-02"),
      cancel("group-81", %{"refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2027-11-03")["credit"] == credit_row(0, %{}, 0)

    assert report(conn, "2027-11-03")["late_adjustments"] ==
             late(
               [{"ams-canal", %{"converted_to_credit_cents" => 100}}],
               %{"issued_cents" => 110, "expired_cents" => 110}
             )

    assert_reconciled(conn, "2027-11-03")
  end

  test "late credit consumption and shortfall absorption remain separate from ordinary movements",
       %{
         conn: conn
       } do
    payment = payment(100)

    batch(conn, [
      start(),
      booking(),
      payment,
      cancel("group-81", %{"refund_method" => "hotel_credit"}),
      booking("refundable", "p"),
      booking("retained", "p") |> Map.put("rate_plan", "advance_purchase"),
      operation("apply_hotel_credit", %{"group_id" => "refundable", "amount_cents" => 50}),
      operation("apply_hotel_credit", %{"group_id" => "retained", "amount_cents" => 30}),
      close("2026-11-01"),
      operation("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]}),
      cancel("retained"),
      cancel("refundable", %{"occurred_on" => "2026-11-02"})
    ])

    assert report(conn, "2026-11-02")["credit"] == credit_row(110, %{"absorbed_cents" => 50}, 0)

    assert report(conn, "2026-11-02")["late_adjustments"]["credit"] ==
             fields(@credit_fields, %{"revoked_cents" => 30, "consumed_cents" => 30})

    assert Reservations.ledger(~D[2026-11-02]).credit_shortfall_cents == 0
    assert_reconciled(conn, "2026-11-02")
  end

  defp start, do: operation("start_finance_reporting", %{"starts_on" => "2026-11-01"})

  defp close(date),
    do:
      operation("close_finance_period", %{"period_end_on" => date})
      |> Map.delete("group_id")

  defp booking(id \\ "group-81", property \\ "ams-canal"),
    do:
      open_group(%{
        "group_id" => id,
        "property_id" => property,
        "arrival_on" => "2029-12-10",
        "departure_on" => "2029-12-13"
      })

  defp payment(amount, date \\ "2026-11-01"),
    do: operation("record_cash_payment", %{"amount_cents" => amount, "occurred_on" => date})

  defp transfer(destination, amount),
    do:
      operation("transfer_deposit", %{
        "source_group_id" => "group-81",
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  defp cancel(group, attrs \\ %{}),
    do: operation("cancel_group", Map.put(attrs, "group_id", group))

  defp batch(conn, operations),
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

  # The response contains only data, so comparing its encoded body also verifies
  # the published value's byte stability, not just equality after JSON decoding.
  defp report_bytes(conn, date),
    do: conn |> get("/api/v1/finance/daily-report", %{"date" => date}) |> response(200)

  defp fields(names, values), do: Map.merge(Map.new(names, &{&1, 0}), values)

  defp cash_row(property, opening, movements, closing),
    do: %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" => fields(@cash_fields, movements),
      "closing_held_cents" => closing
    }

  defp credit_row(opening, movements, closing),
    do: %{
      "opening_liability_cents" => opening,
      "movements" => fields(@credit_fields, movements),
      "closing_liability_cents" => closing
    }

  defp late(cash, credit),
    do: %{
      "cash" =>
        Enum.map(cash, fn {property, movements} ->
          %{"property_id" => property, "movements" => fields(@cash_fields, movements)}
        end),
      "credit" => fields(@credit_fields, credit)
    }

  defp assert_reconciled(conn, date) do
    report = report(conn, date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end
end
