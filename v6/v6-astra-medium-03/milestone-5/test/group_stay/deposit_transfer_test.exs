defmodule GroupStay.DepositTransferTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.Reservations, as: R

  defp op(type, attrs) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2026-01-01"
      },
      attrs
    )
  end

  defp run(operation), do: hd(R.batch([operation]))

  defp open(id, attrs \\ %{}) do
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
          "rooms" => Enum.map(~w(a b c), &%{"room_id" => &1, "nightly_rate_cents" => 500})
        },
        attrs
      )
    )
  end

  defp pay(id, group, amount),
    do:
      op(
        "record_cash_payment",
        %{"operation_id" => id, "group_id" => group, "amount_cents" => amount}
      )

  defp transfer(source, dest, amount, attrs \\ %{}),
    do:
      op(
        "transfer_deposit",
        Map.merge(
          %{
            "source_group_id" => source,
            "destination_group_id" => dest,
            "amount_cents" => amount
          },
          attrs
        )
      )

  defp statement(id) do
    {:ok, statement} = R.get_payment(id)
    statement
  end

  defp rooms(id),
    do: Enum.map(R.get_group(id).rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp ledger, do: R.ledger(~D[2026-06-01])

  test "mixed funding moves newest first, fills in draw order, and retries exactly" do
    R.batch([
      open("seed"),
      pay("seed-pay", "seed", 100),
      op("cancel_group", %{"group_id" => "seed", "refund_method" => "hotel_credit"}),
      open("s"),
      open("d"),
      pay("p", "s", 80),
      op("apply_hotel_credit", %{"group_id" => "s", "amount_cents" => 110}),
      pay("q", "s", 50)
    ])

    before = ledger()

    move =
      transfer("s", "d", 170, %{"expected_revision" => 4, "destination_expected_revision" => 1})

    assert %{
             status: "applied",
             source_revision: 5,
             destination_revision: 2,
             source_outstanding_deposit_cents: 230,
             destination_outstanding_deposit_cents: 130
           } = result = run(move)

    assert rooms("s") == [{70, 0}, {0, 0}, {0, 0}]
    assert rooms("d") == [{50, 50}, {10, 60}, {0, 0}]
    assert ledger() == before

    assert statement("p").held_by_group == [
             %{group_id: "d", amount_cents: 10},
             %{group_id: "s", amount_cents: 70}
           ]

    assert statement("q").held_by_group == [%{group_id: "d", amount_cents: 50}]
    refute Map.has_key?(statement("seed-pay"), :held_by_group)
    assert run(move) == result
    assert run(Map.put(move, "amount_cents", 1)).code == "operation_id_conflict"

    assert build_conn() |> get("/api/v1/operations/#{move["operation_id"]}") |> json_response(200) ==
             %{"data" => Jason.decode!(Jason.encode!(result))}
  end

  test "reductions follow global allocation order through repeated transfers and guard original group" do
    payment = pay("p", "s", 250)
    [_, _, _, original] = R.batch([open("s"), open("d"), open("z"), payment])
    run(transfer("s", "d", 150))
    run(transfer("d", "z", 70))
    # Moving back creates the newest allocation, even though s opened first.
    run(transfer("z", "s", 20))

    reduction =
      op("reduce_cash_payment", %{
        "payment_operation_id" => "p",
        "amount_cents" => 40,
        "expected_revision" => 4
      })

    assert %{revision: 5, outstanding_deposit_cents: 200} = run(reduction)

    assert statement("p").held_by_group == [
             %{group_id: "d", amount_cents: 80},
             %{group_id: "s", amount_cents: 100},
             %{group_id: "z", amount_cents: 30}
           ]

    assert R.get_group("d").revision == 3
    assert R.get_group("z").revision == 4
    assert run(payment) == original
    assert run(reduction).revision == 5
    assert ledger().cash_reduced_cents == 40

    assert run(op("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 210})).status ==
             "applied"

    assert statement("p").held_by_group == []
    assert statement("p").reduced_cents == 250
  end

  test "destination policies settle transferred cash and chargeback updates every affected account" do
    R.batch([
      open("s"),
      open("d"),
      open("n", %{"rate_plan" => "advance_purchase"}),
      pay("p", "s", 300),
      transfer("s", "d", 100),
      transfer("s", "n", 100)
    ])

    run(op("cancel_group", %{"group_id" => "d"}))
    run(op("cancel_group", %{"group_id" => "n"}))
    assert statement("p").refunded_cents == 100
    assert statement("p").retained_cents == 100
    before = Map.new(~w(s d n), &{&1, R.get_group(&1).revision})
    charge = op("charge_back_payment", %{"payment_operation_id" => "p"})
    assert %{charged_back_cents: 300, revision: 5} = run(charge)
    for id <- ~w(s d n), do: assert(R.get_group(id).revision == before[id] + 1)
    assert ledger().cash_refunded_cents == 0
    assert ledger().cash_retained_cents == 0
    assert ledger().cash_charged_back_cents == 300
    assert statement("p").held_by_group == []
    assert run(charge).revision == 5
  end

  test "transferred credit retains expiry and absorbs clawback on destination restoration" do
    R.batch([
      open("seed"),
      pay("p", "seed", 100),
      op("cancel_group", %{"group_id" => "seed", "refund_method" => "hotel_credit"}),
      open("s"),
      open("d"),
      op("apply_hotel_credit", %{"group_id" => "s", "amount_cents" => 110})
    ])

    run(op("charge_back_payment", %{"payment_operation_id" => "p"}))
    before = R.ledger(~D[2027-06-01])
    assert before.credit_shortfall_cents == 110
    assert run(transfer("s", "d", 110, %{"occurred_on" => "2027-06-01"})).status == "applied"
    assert R.ledger(~D[2027-06-01]) == before

    assert run(op("cancel_group", %{"group_id" => "d", "occurred_on" => "2027-06-01"})).credit_issued_cents ==
             0

    assert R.ledger(~D[2027-06-01]).credit_shortfall_cents == 0
    assert R.ledger(~D[2027-06-01]).credit_liability_cents == 0
    assert R.guest_credit("guest", ~D[2027-06-01]).available_cents == 0
  end

  test "conversion after transfer revokes destination entitlement without changing credit-funded groups" do
    R.batch([
      open("s"),
      open("d"),
      open("credit"),
      pay("p", "s", 5),
      transfer("s", "d", 5),
      pay("q", "d", 5)
    ])

    assert run(op("cancel_group", %{"group_id" => "d", "refund_method" => "hotel_credit"})).credit_issued_cents ==
             11

    run(op("apply_hotel_credit", %{"group_id" => "credit", "amount_cents" => 8}))
    before = R.get_group("credit")
    assert run(op("charge_back_payment", %{"payment_operation_id" => "p"})).revision == 4
    assert R.get_group("d").revision == 5
    assert R.get_group("credit") == before
    assert ledger().credit_shortfall_cents == 3
    assert ledger().cash_converted_to_credit_cents == 5
    assert statement("p").charged_back_cents == 5
    assert statement("p").held_by_group == []
  end

  test "existence and both revision guards precede rules; failures are atomic and durable" do
    R.batch([open("s"), open("d"), open("other", %{"guest_id" => "other"}), pay("p", "s", 50)])
    before = {R.get_group("s"), R.get_group("d"), ledger()}

    cases = [
      {transfer("missing", "absent", 1), "group_not_found", "missing"},
      {transfer("s", "absent", 1, %{"expected_revision" => 0}), "group_not_found", "absent"},
      {transfer("s", "d", 0, %{"expected_revision" => 0, "destination_expected_revision" => 0}),
       "stale_revision", "s"},
      {transfer("s", "d", 0, %{"expected_revision" => 2, "destination_expected_revision" => 0}),
       "stale_revision", "d"},
      {transfer("s", "s", 1), "invalid_transfer", nil},
      {transfer("s", "other", 1), "invalid_transfer", nil},
      {transfer("s", "d", 51), "transfer_exceeds_held_funding", nil}
    ]

    for {operation, code, group} <- cases do
      result = run(operation)
      assert result.code == code
      if group, do: assert(result.group_id == group)
      assert run(operation) == result
      assert {R.get_group("s"), R.get_group("d"), ledger()} == before
    end

    for amount <- [0, -1, 1.0, nil, "1"] do
      assert run(transfer("s", "d", amount)).code == "invalid_amount"
    end

    assert run(Map.delete(transfer("s", "d", 1), "amount_cents")).code == "invalid_operation"
    run(pay("full", "d", 300))
    assert run(transfer("s", "d", 1)).code == "transfer_exceeds_outstanding"
    run(op("cancel_group", %{"group_id" => "d"}))
    assert %{code: "group_not_active", group_id: "d"} = run(transfer("s", "d", 1))
    assert %{code: "group_not_active", group_id: "d"} = run(transfer("d", "s", 1))
  end

  test "transfers skip cancelled rooms and refundable credit returns without another bonus" do
    R.batch([
      open("seed"),
      pay("p", "seed", 100),
      op("cancel_group", %{"group_id" => "seed", "refund_method" => "hotel_credit"}),
      open("s"),
      open("d"),
      op("apply_hotel_credit", %{"group_id" => "s", "amount_cents" => 110}),
      op("cancel_rooms", %{"group_id" => "d", "room_ids" => ["a"]})
    ])

    run(transfer("s", "d", 110))
    assert rooms("d") == [{0, 0}, {0, 100}, {0, 10}]

    assert run(op("cancel_group", %{"group_id" => "d", "refund_method" => "hotel_credit"})).credit_issued_cents ==
             0

    assert R.guest_credit("guest", ~D[2026-06-01]).available_cents == 110
    assert ledger().credit_liability_cents == 110
    assert ledger().cash_converted_to_credit_cents == 100
  end
end
