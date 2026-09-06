defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Reservations, Repo, Group, CreditLot}

  defp op(type, attrs) do
    Map.merge(
      %{
        "type" => type,
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "occurred_on" => "2026-10-01"
      },
      attrs
    )
  end

  defp run(op), do: hd(Reservations.batch([op]))

  defp open(id, attrs \\ %{}) do
    run(
      op(
        "open_group",
        Map.merge(
          %{
            "group_id" => id,
            "guest_id" => "guest",
            "property_id" => id,
            "arrival_on" => "2028-12-01",
            "departure_on" => "2028-12-02",
            "rate_plan" => "flexible",
            "rooms" => for(i <- 1..3, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500})
          },
          attrs
        )
      )
    )
  end

  defp pay(id, amount),
    do: op("record_cash_payment", %{"group_id" => id, "amount_cents" => amount})

  defp transfer(a, b, amount, attrs \\ %{}),
    do:
      op(
        "transfer_deposit",
        Map.merge(
          %{"source_group_id" => a, "destination_group_id" => b, "amount_cents" => amount},
          attrs
        )
      )

  defp statement(payment) do
    build_conn()
    |> get("/api/v1/payments/#{payment["operation_id"]}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger, do: Reservations.ledger(~D[2026-10-01])

  test "transfers draw newest funding and corrections follow global allocation order" do
    open("a")
    open("b")
    p = pay("a", 250)
    original = run(p)
    before = ledger()

    move =
      transfer("a", "b", 125, %{"expected_revision" => 2, "destination_expected_revision" => 1})

    assert %{
             source_revision: 3,
             destination_revision: 2,
             source_outstanding_deposit_cents: 175,
             destination_outstanding_deposit_cents: 175
           } = result = run(move)

    assert run(move) == result
    assert ledger() == before

    assert statement(p)["held_by_group"] == [
             %{"group_id" => "a", "amount_cents" => 125},
             %{"group_id" => "b", "amount_cents" => 125}
           ]

    # A later transfer back creates the newest allocations on a.
    run(transfer("b", "a", 50))

    reduction =
      op("reduce_cash_payment", %{
        "payment_operation_id" => p["operation_id"],
        "amount_cents" => 75,
        "expected_revision" => 4
      })

    assert %{revision: 5} = run(reduction)
    assert Reservations.get("b").revision == 4

    assert statement(p)["held_by_group"] == [
             %{"group_id" => "a", "amount_cents" => 125},
             %{"group_id" => "b", "amount_cents" => 50}
           ]

    assert run(p) == original
    run(op("cancel_group", %{"group_id" => "b"}))
    assert statement(p)["refunded_cents"] == 50

    assert %{revision: 6, charged_back_cents: 175} =
             run(op("charge_back_payment", %{"payment_operation_id" => p["operation_id"]}))

    assert Reservations.get("b").revision == 6
    assert statement(p)["held_by_group"] == []
    assert ledger().cash_refunded_cents == 0
    assert ledger().cash_charged_back_cents == 175
    assert ledger().cash_reduced_cents == 75
  end

  test "mixed funding preserves draw order and expired credit restores to its original lot" do
    open("issuer")
    run(pay("issuer", 100))
    run(op("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}))
    open("a")
    open("b")
    p = pay("a", 70)
    run(p)
    run(op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 110}))
    q = pay("a", 40)
    run(q)
    before = ledger()
    run(transfer("a", "b", 170, %{"occurred_on" => "2027-11-01"}))
    assert ledger() == before

    assert Enum.map(
             Reservations.get("b").rooms,
             &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
           ) == [{40, 60}, {20, 50}, {0, 0}]

    run(op("cancel_group", %{"group_id" => "b", "occurred_on" => "2027-11-01"}))
    assert Reservations.credit("guest", ~D[2027-11-01]).available_cents == 0
    assert Reservations.ledger(~D[2027-11-01]).credit_liability_cents == 0
    assert statement(q)["refunded_cents"] == 40
    assert statement(p)["held_cents"] == 50
  end

  test "destination conversion entitlements and clawbacks preserve credit shortfall rules" do
    open("a")
    open("b")
    open("c")
    p = pay("a", 100)
    run(p)
    run(transfer("a", "b", 100))
    run(op("cancel_group", %{"group_id" => "b", "refund_method" => "hotel_credit"}))
    run(op("apply_hotel_credit", %{"group_id" => "c", "amount_cents" => 110}))
    c = Reservations.get("c")

    assert %{revision: 4} =
             run(op("charge_back_payment", %{"payment_operation_id" => p["operation_id"]}))

    assert Reservations.get("c") == c
    assert Reservations.get("b").revision == 4
    assert ledger().cash_converted_to_credit_cents == 0
    assert ledger().credit_shortfall_cents == 110
    run(op("cancel_group", %{"group_id" => "c"}))
    assert ledger().credit_shortfall_cents == 0
    assert ledger().credit_liability_cents == 0
  end

  test "HTTP batches settle transferred cash using the destination policy" do
    open("a")
    open("b", %{"rate_plan" => "advance_purchase"})
    p = pay("a", 100)
    operations = [p, transfer("a", "b", 100), op("cancel_group", %{"group_id" => "b"})]

    response =
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)

    assert [
             %{"status" => "applied"},
             %{"source_revision" => 3, "destination_revision" => 2},
             %{"retained_cents" => 100, "refunded_cents" => 0}
           ] = response["results"]

    assert statement(p)["retained_cents"] == 100
    assert statement(p)["held_by_group"] == []
    assert ledger().cash_retained_cents == 100

    assert build_conn()
           |> post("/api/v1/partner-batches", %{"operations" => operations})
           |> json_response(200) == response
  end

  test "validation precedence, atomic rejection, durable retries, and batch visibility" do
    open("a")
    open("b")
    open("other", %{"guest_id" => "other"})
    open("cancelled")
    run(op("cancel_group", %{"group_id" => "cancelled"}))
    run(pay("a", 100))
    before = {Repo.all(Group), Repo.all(CreditLot), ledger()}

    cases = [
      {transfer("missing", "also-missing", 1), "group_not_found", "missing"},
      {transfer("a", "missing", 1, %{"expected_revision" => 0}), "group_not_found", "missing"},
      {transfer("a", "b", 0, %{"expected_revision" => 0, "destination_expected_revision" => 0}),
       "stale_revision", "a"},
      {transfer("a", "b", 0, %{"destination_expected_revision" => 0}), "stale_revision", "b"},
      {transfer("a", "a", 1), "invalid_transfer", nil},
      {transfer("a", "other", 1), "invalid_transfer", nil},
      {transfer("a", "cancelled", 1), "group_not_active", "cancelled"},
      {transfer("cancelled", "a", 1), "group_not_active", "cancelled"},
      {transfer("a", "b", 0), "invalid_amount", nil},
      {transfer("a", "b", 1.5), "invalid_amount", nil},
      {transfer("a", "b", 101), "transfer_exceeds_held_funding", nil}
    ]

    for {operation, code, id} <- cases do
      assert %{code: ^code} = result = run(operation)
      if id, do: assert(result.group_id == id)
      assert run(operation) == result
      assert {Repo.all(Group), Repo.all(CreditLot), ledger()} == before
    end

    run(pay("b", 300))
    assert %{code: "transfer_exceeds_outstanding"} = run(transfer("a", "b", 1))
    open("fresh")
    move = transfer("a", "fresh", 100)

    [applied, reduced] =
      Reservations.batch([
        move,
        op("reduce_cash_payment", %{"payment_operation_id" => "missing", "amount_cents" => 1})
      ])

    assert applied.status == "applied"
    assert reduced.code == "operation_not_found"
    assert %{code: "operation_id_conflict"} = run(Map.put(move, "amount_cents", 99))
  end
end
