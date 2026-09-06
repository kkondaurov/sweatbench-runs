defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.Finance.Movement

  defp op(id, type, extra \\ %{}, on \\ "2027-02-01") do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => on}, extra)
  end

  defp open(id, property) do
    op("open-#{id}", "open_group", %{
      "group_id" => id,
      "property_id" => property,
      "guest_id" => "guest",
      "arrival_on" => "2029-06-01",
      "departure_on" => "2029-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
    })
  end

  defp pay(id, amount, group \\ "a"),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount})

  defp start, do: op("start", "start_finance_reporting", %{"starts_on" => "2027-02-01"})

  defp apply!(ops) do
    results = Reservations.batch(List.wrap(ops))
    assert Enum.all?(results, &(&1.status == "applied")), inspect(results)
    results
  end

  defp report(on \\ "2027-02-01") do
    build_conn()
    |> get("/api/v1/finance/daily-report", %{"date" => on})
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp cancel(id, group, on \\ "2027-02-01", method \\ "cash"),
    do: op(id, "cancel_group", %{"group_id" => group, "refund_method" => method}, on)

  test "validation, exact inception shape, durable rejection and replay" do
    for params <- [%{}, %{"date" => "bad"}, %{"date" => ["2027-02-01"]}] do
      assert build_conn() |> get("/api/v1/finance/daily-report", params) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-02-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    bad = op("bad", "start_finance_reporting")
    assert [%{code: "invalid_reporting_date"}] = Reservations.batch([bad])

    assert [%{operation_id: "start", status: "applied", starts_on: "2027-02-01"} = original] =
             apply!(start())

    assert map_size(original) == 3
    assert [^original] = Reservations.batch([start()])

    assert [%{code: "reporting_already_started"}] =
             Reservations.batch([Map.put(start(), "operation_id", "second")])

    assert [%{code: "operation_id_conflict"}] =
             Reservations.batch([Map.put(start(), "starts_on", "2028-01-01")])

    assert [%{code: "invalid_reporting_date"}] = Reservations.batch([bad])

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-01-31")
           |> json_response(404)
  end

  test "opening cutoff, property transfers, reductions and settled chargeback reversals" do
    apply!([open("a", "alpha"), open("b", "beta"), pay("senior", 500), start(), pay("p", 1000)])

    apply!(
      op("transfer", "transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 600
      })
    )

    apply!(
      op("reduce", "reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 100})
    )

    apply!(cancel("cancel", "b"))
    apply!(op("charge", "charge_back_payment", %{"payment_operation_id" => "p"}))
    [a, b] = report()["cash"]
    assert a["opening_held_cents"] == 500
    assert a["closing_held_cents"] == 500

    assert a["movements"] == %{
             "received_cents" => 1000,
             "transferred_in_cents" => 0,
             "transferred_out_cents" => 600,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 400
           }

    assert b["closing_held_cents"] == 0
    assert b["movements"]["refunded_cents"] == 0
    assert b["movements"]["charged_back_cents"] == 500
    assert b["movements"]["reduced_cents"] == 100
    assert b["movements"]["transferred_in_cents"] == 600

    assert Enum.sum(Enum.map(report()["cash"], & &1["closing_held_cents"])) ==
             Reservations.ledger(~D[2027-02-01]).cash_held_cents
  end

  test "expiry without operations, redemption pauses expiry and late restoration expires" do
    apply!([
      open("a", "alpha"),
      open("b", "beta"),
      pay("p", 1000),
      start(),
      cancel("issue", "a", "2027-02-01", "hotel_credit")
    ])

    redeem = op("redeem", "apply_hotel_credit", %{"group_id" => "b", "amount_cents" => 400})
    apply!(redeem)
    assert report()["credit"]["movements"]["issued_cents"] == 1100
    assert report("2028-02-02")["credit"]["movements"]["expired_cents"] == 700
    assert report("2028-02-02")["credit"]["closing_liability_cents"] == 400
    apply!(cancel("restore", "b", "2028-02-03"))
    assert report("2028-02-03")["credit"]["movements"]["expired_cents"] == 400
    assert report("2028-02-03")["credit"]["closing_liability_cents"] == 0
    count = Repo.aggregate(Movement, :count)
    expected = report()
    Reservations.batch([redeem])
    report("2030-01-01")
    assert report() == expected
    assert Repo.aggregate(Movement, :count) == count
  end

  test "revocation and absorption remain distinct, including expired returns" do
    apply!([
      open("a", "alpha"),
      open("b", "beta"),
      pay("p", 1000),
      start(),
      cancel("issue", "a", "2027-02-01", "hotel_credit"),
      op("redeem", "apply_hotel_credit", %{"group_id" => "b", "amount_cents" => 800})
    ])

    apply!(op("charge", "charge_back_payment", %{"payment_operation_id" => "p"}))
    assert report()["credit"]["movements"]["revoked_cents"] == 300
    apply!(cancel("restore", "b", "2028-03-01"))
    credit = report("2028-03-01")["credit"]
    assert credit["movements"]["absorbed_cents"] == 800
    assert credit["movements"]["expired_cents"] == 0

    assert credit["closing_liability_cents"] ==
             Reservations.ledger(~D[2028-03-01]).credit_liability_cents
  end

  test "pre-inception lots and settled properties, backdating and failed operations" do
    apply!([
      open("a", "alpha"),
      open("b", "beta"),
      pay("p", 1000),
      cancel("issue", "a", "2027-02-01", "hotel_credit"),
      start()
    ])

    assert report()["cash"] == []
    assert report()["credit"]["opening_liability_cents"] == 1100
    assert report("2028-02-02")["credit"]["closing_liability_cents"] == 0
    payment = pay("later", 100, "b") |> Map.put("occurred_on", "2026-01-01")
    [applied, rejected] = Reservations.batch([payment, pay("too-much", 5000, "b")])
    assert applied.status == "applied"
    assert rejected.status == "rejected"
    assert hd(report()["cash"])["movements"]["received_cents"] == 100
    assert hd(report("2027-02-02")["cash"])["opening_held_cents"] == 100
  end

  test "mixed transfers report cash only, including both columns at the same property" do
    apply!([
      open("a", "hotel"),
      open("b", "hotel"),
      open("c", "other"),
      pay("seed", 100),
      cancel("issue", "a", "2027-02-01", "hotel_credit"),
      start(),
      pay("cash", 300, "b"),
      op("credit", "apply_hotel_credit", %{"group_id" => "b", "amount_cents" => 110})
    ])

    # Credit is newest and moves first; the remaining 90 cents are cash.
    apply!(
      op("move", "transfer_deposit", %{
        "source_group_id" => "b",
        "destination_group_id" => "c",
        "amount_cents" => 200
      })
    )

    apply!(open("d", "hotel"))

    apply!(
      op("same", "transfer_deposit", %{
        "source_group_id" => "b",
        "destination_group_id" => "d",
        "amount_cents" => 50
      })
    )

    [hotel, other] = report()["cash"]
    assert hotel["movements"]["transferred_in_cents"] == 50
    assert hotel["movements"]["transferred_out_cents"] == 140
    assert other["movements"]["transferred_in_cents"] == 90
    assert report()["credit"]["closing_liability_cents"] == 110
    assert Enum.all?(report()["credit"]["movements"], fn {_, n} -> n == 0 end)
  end

  test "nonrefundable credit is consumed while cash is retained" do
    apply!([
      open("a", "alpha"),
      open("b", "beta"),
      pay("seed", 100),
      start(),
      cancel("issue", "a", "2027-02-01", "hotel_credit"),
      pay("cash", 100, "b"),
      op("credit", "apply_hotel_credit", %{"group_id" => "b", "amount_cents" => 110})
    ])

    apply!(cancel("late", "b", "2029-05-31"))
    daily = report("2029-05-31")
    assert daily["credit"]["movements"]["consumed_cents"] == 110
    assert daily["credit"]["closing_liability_cents"] == 0
    assert hd(daily["cash"])["movements"]["retained_cents"] == 100
  end

  test "late backdated credit application corrects the prior expiry report" do
    apply!([
      open("a", "alpha"),
      open("b", "beta"),
      pay("seed", 1000),
      start(),
      cancel("issue", "a", "2027-02-01", "hotel_credit")
    ])

    assert report("2028-02-02")["credit"]["movements"]["expired_cents"] == 1100

    apply!(
      op(
        "backdated",
        "apply_hotel_credit",
        %{"group_id" => "b", "amount_cents" => 500},
        "2028-02-01"
      )
    )

    assert report("2028-02-02")["credit"]["movements"]["expired_cents"] == 600
    assert report("2028-02-02")["credit"]["closing_liability_cents"] == 500
    assert report("2028-02-01")["credit"]["closing_liability_cents"] == 1100
  end

  test "equivalent batch and sequential submissions produce the same reports" do
    operations = [
      open("a", "alpha"),
      open("b", "beta"),
      pay("seed", 100),
      start(),
      pay("cash", 100, "b"),
      cancel("issue", "a", "2027-02-01", "hotel_credit"),
      op("credit", "apply_hotel_credit", %{"group_id" => "b", "amount_cents" => 60})
    ]

    {:error, expected} =
      Repo.transaction(fn ->
        apply!(operations)
        Repo.rollback({report(), report("2028-02-02")})
      end)

    Enum.each(operations, &apply!/1)
    assert {report(), report("2028-02-02")} == expected
  end

  test "chargebacks reverse prior-day settlement at its destination property" do
    apply!([
      open("a", "alpha"),
      open("b", "beta"),
      Map.put(pay("p", 500), "occurred_on", "2030-01-01"),
      start()
    ])

    assert hd(report()["cash"])["opening_held_cents"] == 500

    apply!(
      op("move", "transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 500
      })
    )

    apply!(cancel("refund", "b"))

    assert Enum.find(report()["cash"], &(&1["property_id"] == "beta"))["movements"][
             "refunded_cents"
           ] == 500

    apply!(op("charge", "charge_back_payment", %{"payment_operation_id" => "p"}, "2027-02-02"))
    assert [cash] = report("2027-02-02")["cash"]
    assert cash["property_id"] == "beta"
    assert cash["movements"]["refunded_cents"] == -500
    assert cash["movements"]["charged_back_cents"] == 500
    assert cash["opening_held_cents"] == 0
    assert cash["closing_held_cents"] == 0
  end
end
