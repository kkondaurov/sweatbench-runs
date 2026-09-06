defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Reservations, Repo, Group, CreditLot}

  defp op(type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "#{type}-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2026-10-01",
        "group_id" => "g"
      },
      attrs
    )
  end

  defp open(id \\ "g", rates \\ [500, 500, 500]) do
    op("open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-01",
      "departure_on" => "2026-12-02",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.with_index(rates, fn rate, index ->
          %{"room_id" => "r#{index}", "nightly_rate_cents" => rate}
        end)
    })
  end

  defp run(op), do: hd(Reservations.batch([op]))

  defp pay(id, amount, group \\ "g"),
    do:
      op("record_cash_payment", %{
        "operation_id" => id,
        "amount_cents" => amount,
        "group_id" => group
      })

  defp adjust(type, id, attrs \\ %{}),
    do: op(type, Map.put(attrs, "payment_operation_id", id)) |> Map.delete("group_id")

  defp statement(id),
    do: build_conn() |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger, do: Reservations.ledger(~D[2026-10-01])

  test "room cancellation and reductions preserve payment provenance, order, and retries" do
    run(open())
    original = pay("p", 250)
    result = run(original)
    assert Enum.map(Reservations.get("g").rooms, & &1["cash_paid_cents"]) == [100, 100, 50]
    cancellation = op("cancel_rooms", %{"room_ids" => ["r1"]})
    assert %{refunded_cents: 100, cancelled_room_ids: ["r1"], revision: 3} = run(cancellation)

    reduction =
      adjust("reduce_cash_payment", "p", %{"amount_cents" => 75, "expected_revision" => 3})

    assert %{revision: 4, outstanding_deposit_cents: 125} = run(reduction)
    assert Enum.map(Reservations.get("g").rooms, & &1["cash_paid_cents"]) == [75, 0, 0]
    assert run(original) == result
    assert run(reduction).revision == 4
    assert run(cancellation).revision == 3

    assert statement("p") == %{
             "payment_operation_id" => "p",
             "original_group_id" => "g",
             "recorded_cents" => 250,
             "held_cents" => 75,
             "refunded_cents" => 100,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 75,
             "charged_back_cents" => 0
           }

    run(pay("q", 125))

    assert %{cancelled_room_ids: ["r0", "r2"], retained_cents: 200} =
             run(op("cancel_rooms", %{"room_ids" => ["r2", "r0"], "occurred_on" => "2026-11-30"}))

    assert Reservations.get("g").status == "cancelled"
    assert Reservations.get("g").lodging_total_cents == 0
    charge = adjust("charge_back_payment", "p")
    assert %{charged_back_cents: 175, revision: 7, outstanding_deposit_cents: 0} = run(charge)
    assert run(charge).revision == 7
    assert statement("p")["charged_back_cents"] == 175
    assert statement("q")["retained_cents"] == 125
    assert ledger().cash_refunded_cents == 0
    assert ledger().cash_retained_cents == 125
    assert ledger().cash_reduced_cents == 75
    assert ledger().cash_charged_back_cents == 175
  end

  test "combined rounding, fungible clawback, restoration absorption, and affected revisions" do
    run(open("g", [25, 25]))
    run(pay("p", 5))
    run(pay("q", 5))

    assert %{credit_issued_cents: 11} =
             run(
               op("cancel_rooms", %{"room_ids" => ["r1", "r0"], "refund_method" => "hotel_credit"})
             )

    [lot] = Repo.all(CreditLot)
    assert lot.entitlements == %{"p" => 6, "q" => 5}
    run(open("destination", [25, 25, 25]))
    run(op("apply_hotel_credit", %{"group_id" => "destination", "amount_cents" => 9}))
    destination = Reservations.get("destination")
    assert %{charged_back_cents: 5} = run(adjust("charge_back_payment", "p"))
    assert Reservations.get("destination") == destination
    assert ledger().credit_liability_cents == 9
    assert ledger().credit_shortfall_cents == 4
    assert Reservations.credit("guest", ~D[2026-10-01]).available_cents == 0
    run(op("cancel_rooms", %{"group_id" => "destination", "room_ids" => ["r0"]}))
    assert ledger().credit_shortfall_cents == 0
    assert ledger().credit_liability_cents == 5
    assert Reservations.credit("guest", ~D[2026-10-01]).available_cents == 1
    run(adjust("charge_back_payment", "q"))
    assert ledger().credit_shortfall_cents == 4
    run(op("cancel_group", %{"group_id" => "destination", "occurred_on" => "2026-11-30"}))
    assert ledger().credit_shortfall_cents == 0
    assert ledger().credit_liability_cents == 0
  end

  test "chargebacks remove held cash, and reductions compose to the exact remaining amount" do
    run(open())
    run(pay("p", 250))
    run(adjust("reduce_cash_payment", "p", %{"amount_cents" => 25}))
    run(adjust("reduce_cash_payment", "p", %{"amount_cents" => 25}))

    assert %{charged_back_cents: 200, outstanding_deposit_cents: 300} =
             run(adjust("charge_back_payment", "p"))

    assert Enum.map(Reservations.get("g").rooms, & &1["cash_paid_cents"]) == [0, 0, 0]
    run(pay("q", 200))

    assert %{amount_cents: 200} =
             run(adjust("reduce_cash_payment", "q", %{"amount_cents" => 200}))

    assert %{code: "payment_not_chargeable"} = run(adjust("charge_back_payment", "q"))

    assert %{code: "payment_not_reducible"} =
             run(adjust("reduce_cash_payment", "q", %{"amount_cents" => 1}))
  end

  test "validation is atomic, revision checks take precedence, and rejected results remain durable" do
    opened = open()
    run(opened)
    run(pay("p", 100))
    rejected = pay("bad", 999)
    run(rejected)
    before = {Repo.all(Group), Repo.all(CreditLot), ledger()}

    cases = [
      {op("cancel_rooms", %{"room_ids" => []}), "invalid_rooms"},
      {op("cancel_rooms", %{"room_ids" => ["r0", "r0"]}), "invalid_rooms"},
      {op("cancel_rooms", %{"room_ids" => ["r0", "missing"]}), "invalid_rooms"},
      {op("cancel_rooms", %{"room_ids" => nil, "expected_revision" => 0}), "stale_revision"},
      {op("cancel_rooms", %{
         "room_ids" => ["r0"],
         "refund_method" => "hotel_credit",
         "occurred_on" => "2026-11-30"
       }), "refund_method_not_available"},
      {adjust("reduce_cash_payment", "missing", %{"amount_cents" => 1}), "operation_not_found"},
      {adjust("reduce_cash_payment", opened["operation_id"], %{"amount_cents" => 1}),
       "payment_not_reducible"},
      {adjust("reduce_cash_payment", "bad", %{"amount_cents" => 1}), "payment_not_reducible"},
      {adjust("reduce_cash_payment", "p", %{"amount_cents" => 0}), "invalid_amount"},
      {adjust("reduce_cash_payment", "p", %{"amount_cents" => 101}),
       "reduction_exceeds_held_cash"},
      {adjust("reduce_cash_payment", "p", %{"amount_cents" => 0, "expected_revision" => 1}),
       "stale_revision"},
      {adjust("charge_back_payment", "bad"), "payment_not_chargeable"},
      {adjust("charge_back_payment", "missing"), "operation_not_found"},
      {adjust("charge_back_payment", "p", %{"expected_revision" => 1}), "stale_revision"}
    ]

    for {operation, code} <- cases do
      assert %{code: ^code} = run(operation)
      assert {Repo.all(Group), Repo.all(CreditLot), ledger()} == before
    end

    for {id, status, code} <- [
          {"missing", 404, "operation_not_found"},
          {"bad", 422, "payment_not_reconcilable"},
          {opened["operation_id"], 422, "payment_not_reconcilable"}
        ] do
      assert build_conn() |> get("/api/v1/payments/#{id}") |> json_response(status) == %{
               "error" => %{"code" => code}
             }
    end

    stale = adjust("charge_back_payment", "p", %{"expected_revision" => 1})
    result = run(stale)
    run(adjust("charge_back_payment", "p"))
    assert run(stale) == result
    assert %{code: "operation_id_conflict"} = run(Map.put(stale, "expected_revision", 3))
    assert %{code: "payment_not_chargeable"} = run(adjust("charge_back_payment", "p"))
  end

  test "expired restoration absorbs clawback first and one payment can contribute to multiple lots" do
    run(open("g", [25, 25]))
    run(pay("p", 10))

    for room <- ["r0", "r1"] do
      assert %{credit_issued_cents: 6} =
               run(op("cancel_rooms", %{"room_ids" => [room], "refund_method" => "hotel_credit"}))
    end

    run(
      open("destination", [25, 25, 25])
      |> Map.merge(%{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-02"})
    )

    run(op("apply_hotel_credit", %{"group_id" => "destination", "amount_cents" => 10}))
    assert %{charged_back_cents: 10} = run(adjust("charge_back_payment", "p"))
    assert ledger().credit_shortfall_cents == 10
    assert Reservations.ledger(~D[2027-10-02]).credit_liability_cents == 10

    run(
      op("cancel_rooms", %{
        "group_id" => "destination",
        "room_ids" => ["r0"],
        "occurred_on" => "2027-10-02"
      })
    )

    assert Reservations.ledger(~D[2027-10-02]).credit_shortfall_cents == 5
    assert Enum.sum(Enum.map(Repo.all(CreditLot), & &1.unrecovered_cents)) == 5
    run(op("cancel_group", %{"group_id" => "destination", "occurred_on" => "2027-10-02"}))
    assert Reservations.ledger(~D[2027-10-02]).credit_liability_cents == 0
    assert Enum.sum(Enum.map(Repo.all(CreditLot), & &1.unrecovered_cents)) == 0
    assert Reservations.credit("guest", ~D[2027-10-02]).available_cents == 0
  end
end
