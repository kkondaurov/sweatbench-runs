defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  defp op(type, attrs \\ %{}, on \\ "2026-10-01") do
    Map.merge(
      %{
        "operation_id" => "finance-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => on
      },
      attrs
    )
  end

  defp open(id, property \\ nil) do
    op("open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => property || id,
      "arrival_on" => "2028-12-01",
      "departure_on" => "2028-12-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
    })
  end

  defp cash(group, id, amount),
    do:
      op("record_cash_payment", %{
        "operation_id" => id,
        "group_id" => group,
        "amount_cents" => amount
      })

  defp start, do: op("start_finance_reporting", %{"starts_on" => "2026-10-01"})

  defp submit(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => List.wrap(ops)})
      |> json_response(200)
      |> Map.fetch!("results")

  defp report(date \\ "2026-10-01"),
    do:
      build_conn()
      |> get("/api/v1/finance/daily-report", %{"date" => date})
      |> json_response(200)
      |> Map.fetch!("data")

  defp cancel(id, on \\ "2026-10-01"),
    do: op("cancel_group", %{"group_id" => id, "refund_method" => "hotel_credit"}, on)

  defp close(on), do: op("close_finance_period", %{"period_end_on" => on})

  test "close validation, exact durable replay and conflict, including remembered rejections" do
    premature = close("2026-10-01")
    assert [%{"code" => "invalid_period"} = rejected] = submit(premature)
    submit(start())
    assert [rejected] == submit(premature)

    for value <- [nil, "bad", "2026-02-30", [], 1, "2026-09-30"] do
      assert [%{"code" => "invalid_period"}] = submit(close(value))
    end

    cutoff = close("2026-10-01") |> Map.put("expected_revision", -1)
    assert [result] = submit(cutoff)

    assert result == %{
             "operation_id" => cutoff["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-10-01"
           }

    assert [result] == submit(cutoff)

    assert [%{"code" => "operation_id_conflict"}] =
             submit(Map.put(cutoff, "period_end_on", "2026-10-02"))

    assert [%{"code" => "invalid_period"}] = submit(close("2026-10-01"))
    assert report()["status"] == "closed"
    assert report("2026-10-02")["status"] == "open"
    assert report()["late_adjustments"]["cash"] == []
    assert Enum.all?(Map.values(report()["late_adjustments"]["credit"]), &(&1 == 0))
  end

  test "same-batch cutoff clamps only later postings and subsequent closes never move them" do
    payment = cash("a", "late", 50)

    submit([
      open("a"),
      start(),
      cash("a", "before", 100),
      close("2026-10-01"),
      payment,
      cash("a", "future", 30) |> Map.put("occurred_on", "2026-10-04")
    ])

    published = report()
    assert hd(published["cash"])["closing_held_cents"] == 100
    assert hd(published["cash"])["movements"]["received_cents"] == 100
    second = report("2026-10-02")
    assert hd(second["cash"])["opening_held_cents"] == 100
    assert hd(second["cash"])["closing_held_cents"] == 150
    assert hd(second["cash"])["movements"]["received_cents"] == 0
    assert hd(second["late_adjustments"]["cash"])["movements"]["received_cents"] == 50
    assert hd(report("2026-10-04")["cash"])["movements"]["received_cents"] == 30
    submit([close("2026-10-03"), payment, cash("a", "later", 20)])
    assert report() == published
    assert report("2026-10-02") == Map.put(second, "status", "closed")

    assert hd(report("2026-10-04")["late_adjustments"]["cash"])["movements"]["received_cents"] ==
             20

    assert hd(report("2026-10-04")["cash"])["closing_held_cents"] == 200
    before = report("2026-10-04")
    submit([cash("a", "invalid", 10000), %{"operation_id" => "malformed"}, nil])
    assert report("2026-10-04") == before
  end

  test "late transfers, reductions and signed settled chargebacks retain property classifications" do
    submit([
      open("a"),
      open("b"),
      start(),
      cash("a", "p", 200),
      close("2026-10-01"),
      op("transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 150
      }),
      op("cancel_group", %{"group_id" => "b"}),
      op("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 20}),
      close("2026-10-02")
    ])

    published = report("2026-10-02")
    [a, b] = published["late_adjustments"]["cash"]
    assert a["movements"]["transferred_out_cents"] == 150
    assert a["movements"]["reduced_cents"] == 20
    assert b["movements"]["transferred_in_cents"] == 150
    assert b["movements"]["refunded_cents"] == 150
    submit(op("charge_back_payment", %{"payment_operation_id" => "p"}))
    assert report("2026-10-02") == published
    [a, b] = report("2026-10-03")["late_adjustments"]["cash"]
    assert a["movements"]["charged_back_cents"] == 30
    assert b["movements"]["refunded_cents"] == -150
    assert b["movements"]["charged_back_cents"] == 150
    assert Enum.map(report("2026-10-03")["cash"], & &1["property_id"]) == ["a", "b"]
    assert report("2026-10-04")["cash"] == []
    assert GroupStay.Reservations.ledger().cash_charged_back_cents == 180
  end

  test "closed expiry is preserved when backdated credit application and restoration arrive" do
    submit([
      open("seed"),
      cash("seed", "p", 100),
      cancel("seed"),
      open("a"),
      start(),
      close("2027-10-02")
    ])

    published = report("2027-10-02")
    assert published["credit"]["movements"]["expired_cents"] == 110
    submit(op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 40}, "2027-09-01"))
    assert report("2027-10-02") == published
    adjusted = report("2027-10-03")
    assert adjusted["late_adjustments"]["credit"]["expired_cents"] == -40
    assert adjusted["credit"]["closing_liability_cents"] == 40
    submit([close("2027-10-03"), cancel("a", "2027-09-02")])
    assert report("2027-10-03") == Map.put(adjusted, "status", "closed")
    assert report("2027-10-04")["late_adjustments"]["credit"]["expired_cents"] == 40
    assert report("2027-10-04")["credit"]["closing_liability_cents"] == 0
  end

  test "late credit issue changes future ordinary expiry and clawbacks absorb restored credit" do
    submit([
      open("seed"),
      open("a"),
      start(),
      cash("seed", "p", 100),
      close("2026-10-01"),
      cancel("seed"),
      op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 80}),
      op("charge_back_payment", %{"payment_operation_id" => "p"})
    ])

    day = report("2026-10-02")
    assert day["late_adjustments"]["credit"]["issued_cents"] == 110
    assert day["late_adjustments"]["credit"]["revoked_cents"] == 30
    assert day["credit"]["closing_liability_cents"] == 80
    submit([close("2027-10-02"), cancel("a")])
    assert report("2026-10-02") == Map.put(day, "status", "closed")
    assert report("2027-10-03")["late_adjustments"]["credit"]["absorbed_cents"] == 80
    assert report("2027-10-03")["credit"]["closing_liability_cents"] == 0
  end

  test "scheduled expiry remains ordinary after a late issue and later close" do
    submit([open("seed"), start(), cash("seed", "p", 100), close("2026-10-01"), cancel("seed")])
    assert report("2027-10-02")["credit"]["movements"]["expired_cents"] == 110
    submit(close("2027-10-02"))
    assert report("2027-10-02")["credit"]["movements"]["expired_cents"] == 110
    assert report("2027-10-02")["late_adjustments"]["credit"]["expired_cents"] == 0
  end

  test "late expired issuance and nonrefundable consumption reconcile without mutating reads" do
    submit([
      open("seed"),
      open("a"),
      start(),
      cash("seed", "p", 100),
      cancel("seed"),
      op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 60}),
      open("old"),
      cash("old", "old-payment", 100),
      close("2028-12-01"),
      op("cancel_group", %{"group_id" => "a"}, "2028-11-30"),
      cancel("old")
    ])

    day = report("2028-12-02")
    assert day["late_adjustments"]["credit"]["consumed_cents"] == 60
    assert day["late_adjustments"]["credit"]["issued_cents"] == 110
    assert day["late_adjustments"]["credit"]["expired_cents"] == 110
    assert day["credit"]["closing_liability_cents"] == 0

    assert day["credit"]["closing_liability_cents"] ==
             GroupStay.Reservations.ledger(~D[2028-12-02]).credit_liability_cents

    before = GroupStay.Repo.query!("SELECT * FROM finance_movements ORDER BY id").rows

    for date <- ["2028-12-02", "2026-10-01", "2029-01-01", "2028-12-02"] do
      report(date)
    end

    assert GroupStay.Repo.query!("SELECT * FROM finance_movements ORDER BY id").rows == before
    assert report("2028-12-02") == day
  end
end
