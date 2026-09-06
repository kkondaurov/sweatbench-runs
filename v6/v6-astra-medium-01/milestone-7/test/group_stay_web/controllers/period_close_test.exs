defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase
  import GroupStay.OperationFixture
  alias GroupStay.{Repo, Reservations}

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{operations: ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp close(id, on),
    do: operation(id, "close_finance_period", %{"period_end_on" => on}) |> Map.delete("group_id")

  defp start,
    do: operation("start", "start_finance_reporting", %{"starts_on" => "2027-05-02"})

  defp pay(id, amount, on \\ "2027-05-02"),
    do: operation(id, "record_cash_payment", %{"amount_cents" => amount, "occurred_on" => on})

  defp report(on) do
    data =
      build_conn()
      |> get("/api/v1/finance/daily-report?date=" <> on)
      |> json_response(200)
      |> Map.fetch!("data")

    for c <- data["cash"] do
      late = Enum.find(data["late_adjustments"]["cash"], &(&1["property_id"] == c["property_id"]))

      m =
        if late,
          do: Map.merge(c["movements"], late["movements"], fn _, a, b -> a + b end),
          else: c["movements"]

      assert c["closing_held_cents"] ==
               c["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] -
                 Enum.sum(
                   for k <-
                         ~w(refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                       do: m[k]
                 )
    end

    m =
      Map.merge(data["credit"]["movements"], data["late_adjustments"]["credit"], fn _, a, b ->
        a + b
      end)

    assert data["credit"]["closing_liability_cents"] ==
             data["credit"]["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    data
  end

  test "close validation, exact replay, conflict, and remembered rejection" do
    early = close("early", "2027-05-02")
    assert [%{"code" => "invalid_period"}] = batch([early])
    batch([start()])

    for {value, index} <- Enum.with_index([nil, 12, %{}, "bad", "2027-02-29", "2027-05-01"]) do
      assert [%{"code" => "invalid_period"}] = batch([close("bad-#{index}", value)])
    end

    assert [%{"code" => "invalid_period"}] =
             batch([close("missing", nil) |> Map.delete("period_end_on")])

    op = close("close", "2027-05-02") |> Map.put("expected_revision", -1)
    assert [result] = batch([op])

    assert result == %{
             "operation_id" => "close",
             "status" => "applied",
             "period_end_on" => "2027-05-02"
           }

    assert batch([op]) == [result]
    assert [%{"code" => "invalid_period"}] = batch([early])
    assert [%{"code" => "invalid_period"}] = batch([close("same", "2027-05-02")])

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(op, "period_end_on", "2027-05-03")])

    assert report("2027-05-02")["status"] == "closed"
    assert report("2027-05-03")["status"] == "open"
    assert report("2027-05-02")["late_adjustments"]["cash"] == []
  end

  test "same-batch boundaries, later closes, and ordinary and late movements stay separate" do
    batch([
      opening(),
      start(),
      pay("before", 100),
      close("c1", "2027-05-02"),
      pay("after", 200, "2026-01-01"),
      pay("future", 300, "2027-05-05")
    ])

    frozen = report("2027-05-02") |> Jason.encode!()
    day = report("2027-05-03")
    assert [cash] = day["cash"]
    assert cash["opening_held_cents"] == 100
    assert cash["closing_held_cents"] == 300
    assert cash["movements"]["received_cents"] == 0
    assert hd(day["late_adjustments"]["cash"])["movements"]["received_cents"] == 200
    assert hd(report("2027-05-05")["cash"])["movements"]["received_cents"] == 300
    batch([close("c2", "2027-05-04"), pay("late2", 50), pay("normal", 70, "2027-05-05")])
    assert Jason.encode!(report("2027-05-02")) == frozen
    assert report("2027-05-03") == Map.put(day, "status", "closed")
    day = report("2027-05-05")
    assert hd(day["cash"])["movements"]["received_cents"] == 370
    assert hd(day["late_adjustments"]["cash"])["movements"]["received_cents"] == 50
    assert hd(day["cash"])["closing_held_cents"] == Reservations.ledger().cash_held_cents
  end

  test "zero-net late chargebacks retain signed classifications at the settlement property" do
    batch([
      opening(),
      opening("other", "other") |> Map.put("property_id", "another"),
      start(),
      pay("p", 100),
      operation("t", "transfer_deposit", %{
        "source_group_id" => "group",
        "destination_group_id" => "other",
        "amount_cents" => 100
      }),
      operation("refund", "cancel_group", %{"group_id" => "other"}),
      close("c", "2027-05-02")
    ])

    frozen = report("2027-05-02")
    cb = operation("cb", "charge_back_payment", %{"payment_operation_id" => "p"})
    batch([cb])
    day = report("2027-05-03")

    assert [
             %{
               "property_id" => "another",
               "movements" => %{"refunded_cents" => -100, "charged_back_cents" => 100}
             }
           ] = day["late_adjustments"]["cash"]

    assert [%{"opening_held_cents" => 0, "closing_held_cents" => 0}] = day["cash"]
    batch([cb, pay("bad", 99999)])
    assert report("2027-05-03") == day
    assert report("2027-05-02") == frozen
  end

  test "closed expiry stays frozen when backdated redemption and restoration change liability" do
    batch([
      opening(),
      start(),
      pay("p", 1000),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("other", "other"),
      close("c", "2028-05-02")
    ])

    frozen = report("2028-05-02")
    assert frozen["credit"]["movements"]["expired_cents"] == 1100

    batch([
      operation("use", "apply_hotel_credit", %{"group_id" => "other", "amount_cents" => 500})
    ])

    day = report("2028-05-03")
    assert day["late_adjustments"]["credit"]["expired_cents"] == -500
    assert day["credit"]["closing_liability_cents"] == 500
    batch([operation("restore", "cancel_group", %{"group_id" => "other"})])
    assert report("2028-05-03")["credit"]["closing_liability_cents"] == 0
    assert report("2028-05-02") == frozen
    assert Reservations.ledger(~D[2028-05-03]).credit_liability_cents == 0
  end

  test "late issuance schedules future expiry as ordinary and late clawback absorbs restored credit" do
    batch([
      opening(),
      start(),
      pay("p", 1000),
      close("c", "2027-05-02"),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("other", "other"),
      operation("use", "apply_hotel_credit", %{"group_id" => "other", "amount_cents" => 1000})
    ])

    assert report("2027-05-03")["late_adjustments"]["credit"]["issued_cents"] == 1100
    assert report("2028-05-02")["credit"]["movements"]["expired_cents"] == 100

    batch([
      operation("cb", "charge_back_payment", %{"payment_operation_id" => "p"}),
      operation("restore", "cancel_group", %{"group_id" => "other"})
    ])

    late = report("2027-05-03")["late_adjustments"]["credit"]
    assert late["revoked_cents"] == 100
    assert late["absorbed_cents"] == 1000
    assert report("2028-05-02")["credit"]["movements"]["expired_cents"] == 0
  end

  test "batch and sequential closes produce identical reports without read side effects" do
    ops = [
      opening(),
      start(),
      pay("p", 100),
      close("c", "2027-05-02"),
      pay("late", 50),
      close("c2", "2027-05-03"),
      pay("late2", 20)
    ]

    dates = ~w(2027-05-02 2027-05-03 2027-05-04 2030-01-01)

    {:error, expected} =
      Repo.transaction(fn ->
        batch(ops)
        Repo.rollback(Enum.map(dates, &report/1))
      end)

    Enum.each(ops, &batch([&1]))
    assert Enum.map(dates, &report/1) == expected
    Enum.each(Enum.reverse(dates), &report/1)
    assert Enum.map(dates, &report/1) == expected
  end
end
