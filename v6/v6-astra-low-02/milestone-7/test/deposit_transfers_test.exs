defmodule GroupStay.DepositTransfersTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Reservations, Repo, Group, CreditLot, Operation}

  defp op(type, fields) do
    Map.merge(
      %{
        "type" => type,
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "occurred_on" => "2026-10-01"
      },
      fields
    )
  end

  defp open(id, extra \\ %{}) do
    op(
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => id,
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02",
          "rate_plan" => "flexible",
          "rooms" => for(i <- 1..3, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 100})
        },
        extra
      )
    )
  end

  defp apply!(op) do
    [result] = Reservations.batch([op])
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp transfer(source, destination, amount, extra \\ %{}) do
    op(
      "transfer_deposit",
      Map.merge(
        %{
          "source_group_id" => source,
          "destination_group_id" => destination,
          "amount_cents" => amount
        },
        extra
      )
    )
  end

  defp cash(group, amount),
    do: op("record_cash_payment", %{"group_id" => group, "amount_cents" => amount})

  defp group(id), do: Reservations.get_group(id)
  defp ledger, do: Reservations.ledger(~D[2026-10-01])

  defp statement(id) do
    {:ok, data} = Reservations.get_payment(id)

    assert Enum.sum(
             for key <- ~w(held refunded retained converted_to_credit reduced charged_back),
                 do: data[key <> "_cents"]
           ) == data["recorded_cents"]

    if Map.has_key?(data, "held_by_group"),
      do:
        assert(
          Enum.sum(Enum.map(data["held_by_group"], & &1["amount_cents"])) == data["held_cents"]
        )

    data
  end

  test "same-batch transfer, repeated moves and global reverse reductions preserve payment identity" do
    pay = cash("a", 50)

    move =
      transfer("a", "b", 25, %{"expected_revision" => 2, "destination_expected_revision" => 1})

    results = Reservations.batch([open("a"), open("b"), open("c"), pay, move])
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert List.last(results) == %{
             "operation_id" => move["operation_id"],
             "status" => "applied",
             "source_group_id" => "a",
             "destination_group_id" => "b",
             "amount_cents" => 25,
             "source_outstanding_deposit_cents" => 35,
             "destination_outstanding_deposit_cents" => 35,
             "source_revision" => 3,
             "destination_revision" => 2
           }

    before = ledger()
    assert Reservations.batch([move]) == [List.last(results)]
    apply!(transfer("b", "c", 10))
    apply!(transfer("c", "a", 5))
    assert ledger() == before

    assert statement(pay["operation_id"])["held_by_group"] == [
             %{"group_id" => "a", "amount_cents" => 30},
             %{"group_id" => "b", "amount_cents" => 15},
             %{"group_id" => "c", "amount_cents" => 5}
           ]

    revisions = for id <- ~w(a b c), do: group(id).revision

    reduction =
      op("reduce_cash_payment", %{
        "payment_operation_id" => pay["operation_id"],
        "amount_cents" => 12,
        "expected_revision" => group("a").revision
      })

    result = apply!(reduction)
    assert result["outstanding_deposit_cents"] == 35
    assert Enum.map(~w(a b c), &group(&1).cash_paid_cents) == [25, 13, 0]
    assert Enum.map(~w(a b c), &group(&1).revision) == Enum.map(revisions, &(&1 + 1))
    assert Reservations.batch([pay, reduction]) == [Enum.at(results, 3), result]
    assert statement(pay["operation_id"])["reduced_cents"] == 12
    apply!(op("charge_back_payment", %{"payment_operation_id" => pay["operation_id"]}))
    assert statement(pay["operation_id"])["held_by_group"] == []
    assert ledger().cash_charged_back_cents == 38
    assert ledger().cash_reduced_cents == 12
  end

  test "mixed funding draws newest allocation first and transferred expired credit restores without bonus" do
    apply!(open("seed"))
    apply!(cash("seed", 50))
    apply!(op("cancel_group", %{"group_id" => "seed", "refund_method" => "hotel_credit"}))
    apply!(open("a"))
    apply!(open("b", %{"arrival_on" => "2028-03-01", "departure_on" => "2028-03-02"}))
    apply!(cash("a", 10))
    apply!(op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 25}))
    pay = cash("a", 15)
    apply!(pay)
    before = ledger()
    apply!(transfer("a", "b", 40, %{"occurred_on" => "2027-10-02"}))
    assert ledger() == before
    assert {group("a").cash_paid_cents, group("a").credit_paid_cents} == {10, 0}

    assert Enum.map(group("b").rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) ==
             [{15, 5}, {0, 20}, {0, 0}]

    assert Reservations.ledger(~D[2027-10-02]).credit_liability_cents == 25
    result = apply!(op("cancel_group", %{"group_id" => "b", "occurred_on" => "2027-10-02"}))
    assert result["refunded_cents"] == 15
    assert result["credit_issued_cents"] == 0
    assert Reservations.ledger(~D[2027-10-02]).credit_liability_cents == 0
    assert statement(pay["operation_id"])["refunded_cents"] == 15
  end

  test "destination policy, conversion entitlement and shortfall survive transfers and chargeback" do
    apply!(open("a"))
    apply!(open("b"))
    apply!(open("c"))
    apply!(open("nonref", %{"rate_plan" => "advance_purchase"}))
    pay = cash("a", 50)
    original = apply!(pay)
    apply!(transfer("a", "b", 20))
    apply!(transfer("a", "nonref", 10))
    apply!(op("cancel_group", %{"group_id" => "nonref"}))
    assert statement(pay["operation_id"])["retained_cents"] == 10
    result = apply!(op("cancel_group", %{"group_id" => "b", "refund_method" => "hotel_credit"}))
    assert result["credit_issued_cents"] == 22
    apply!(op("apply_hotel_credit", %{"group_id" => "c", "amount_cents" => 22}))
    apply!(transfer("c", "a", 12))
    c = group("c")
    revisions = Enum.map(~w(a b nonref), &group(&1).revision)
    apply!(op("charge_back_payment", %{"payment_operation_id" => pay["operation_id"]}))
    assert group("c") == c
    assert Enum.map(~w(a b nonref), &group(&1).revision) == Enum.map(revisions, &(&1 + 1))
    assert ledger().credit_shortfall_cents == 22
    assert ledger().cash_retained_cents == 0
    assert ledger().cash_converted_to_credit_cents == 0
    assert Reservations.batch([pay]) == [original]
    apply!(op("cancel_group", %{"group_id" => "a"}))
    assert ledger().credit_shortfall_cents == 10
    apply!(op("cancel_group", %{"group_id" => "c", "occurred_on" => "2027-03-01"}))
    assert ledger().credit_shortfall_cents == 0
    assert ledger().credit_liability_cents == 0
    assert statement(pay["operation_id"])["charged_back_cents"] == 50
  end

  test "validation precedence, atomic rejection, durable rejection and HTTP result reads" do
    apply!(open("a"))
    apply!(open("b"))
    apply!(open("other", %{"guest_id" => "other"}))
    apply!(open("inactive"))
    apply!(op("cancel_group", %{"group_id" => "inactive"}))
    apply!(cash("a", 20))
    before = {Repo.all(Group), Repo.all(CreditLot), ledger()}

    for {operation, code, gid} <- [
          {transfer("missing", "absent", 0), "group_not_found", "missing"},
          {transfer("a", "absent", 0, %{"expected_revision" => 0}), "group_not_found", "absent"},
          {transfer("a", "b", 0, %{"expected_revision" => 1, "destination_expected_revision" => 0}),
           "stale_revision", "a"},
          {transfer("a", "b", 0, %{"destination_expected_revision" => 0}), "stale_revision", "b"},
          {transfer("a", "a", 1), "invalid_transfer", nil},
          {transfer("a", "other", 1), "invalid_transfer", nil},
          {transfer("inactive", "a", 1), "group_not_active", "inactive"},
          {transfer("a", "inactive", 1), "group_not_active", "inactive"},
          {transfer("a", "b", 21), "transfer_exceeds_held_funding", nil}
        ] do
      [result] = Reservations.batch([operation])
      assert result["code"] == code
      if gid, do: assert(result["group_id"] == gid)
      assert {Repo.all(Group), Repo.all(CreditLot), ledger()} == before
      assert Reservations.get_operation(operation["operation_id"]) == result
    end

    for amount <- [0, -1, nil, 1.5, "1"] do
      assert [%{"code" => "invalid_amount"}] = Reservations.batch([transfer("a", "b", amount)])
    end

    for key <- ~w(source_group_id destination_group_id) do
      assert [%{"code" => "invalid_operation"}] =
               Reservations.batch([Map.put(transfer("a", "b", 1), key, nil)])
    end

    apply!(cash("b", 60))
    rejected = transfer("a", "b", 1)
    [result] = Reservations.batch([rejected])
    assert result["code"] == "transfer_exceeds_outstanding"
    apply!(transfer("b", "a", 10))
    assert Reservations.batch([rejected]) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             Reservations.batch([Map.put(rejected, "amount_cents", 2)])

    move = transfer("a", "b", 10)

    response =
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => [move]})
      |> json_response(200)

    [applied] = response["results"]
    assert applied["status"] == "applied"

    assert build_conn() |> get("/api/v1/operations/#{move["operation_id"]}") |> json_response(200) ==
             %{"data" => applied}

    assert Repo.get_by!(Operation, operation_id: move["operation_id"]).submission == move
  end
end
