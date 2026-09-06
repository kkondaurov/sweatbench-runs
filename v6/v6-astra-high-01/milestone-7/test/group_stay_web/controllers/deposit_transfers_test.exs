defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{CreditAllocation, CreditEntitlement, CreditLot, FundingAllocation, Group, Repo}

  defp op(type, fields) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2026-11-01"
      },
      fields
    )
  end

  defp open(id, dues \\ [100, 100], fields \\ %{}) do
    op(
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => id,
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-02",
          "rate_plan" => "flexible",
          "rooms" =>
            Enum.with_index(dues, fn due, index ->
              %{"room_id" => "r#{index}", "nightly_rate_cents" => due * 5}
            end)
        },
        fields
      )
    )
  end

  defp pay(group, amount),
    do: op("record_cash_payment", %{"group_id" => group, "amount_cents" => amount})

  defp apply_credit(group, amount),
    do: op("apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount})

  defp cancel(group, fields \\ %{}), do: op("cancel_group", Map.put(fields, "group_id", group))

  defp transfer(source, destination, amount, fields \\ %{}) do
    op(
      "transfer_deposit",
      Map.merge(
        %{
          "source_group_id" => source,
          "destination_group_id" => destination,
          "amount_cents" => amount
        },
        fields
      )
    )
  end

  defp correction(type, payment, fields),
    do: op(type, Map.put(fields, "payment_operation_id", payment["operation_id"]))

  defp reduce(payment, amount, fields \\ %{}),
    do: correction("reduce_cash_payment", payment, Map.put(fields, "amount_cents", amount))

  defp charge(payment, fields \\ %{}), do: correction("charge_back_payment", payment, fields)

  defp submit(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => List.wrap(operations)})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp apply!(operation) do
    assert [result = %{"status" => "applied"}] = submit(operation)
    result
  end

  defp read(path),
    do: build_conn() |> get("/api/v1/#{path}") |> json_response(200) |> Map.fetch!("data")

  defp group(id), do: read("groups/#{id}")
  defp ledger(on \\ "2026-11-01"), do: read("ledger?on=#{on}")
  defp credit(on \\ "2026-11-01"), do: read("guests/guest/credit?on=#{on}")

  defp statement(payment) do
    statement = read("payments/#{payment["operation_id"]}")

    assert statement["recorded_cents"] ==
             Enum.sum(
               for key <-
                     ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                   do: statement[key]
             )

    if Map.has_key?(statement, "held_by_group") do
      assert statement["held_cents"] ==
               Enum.sum(Enum.map(statement["held_by_group"], & &1["amount_cents"]))
    end

    statement
  end

  defp snapshot,
    do:
      Enum.map(
        [Group, CreditLot, CreditAllocation, CreditEntitlement, FundingAllocation],
        &Repo.all/1
      )

  defp reject!(operation, code) do
    before = snapshot()
    assert [result = %{"status" => "rejected", "code" => ^code}] = submit(operation)
    assert snapshot() == before
    result
  end

  defp issue(amount) do
    payment = pay("issuer", amount)

    submit([
      open("issuer", [amount]),
      payment,
      cancel("issuer", %{"refund_method" => "hotel_credit"})
    ])

    payment
  end

  test "mixed funding draws newest allocations across kinds and fills active destination rooms in draw order" do
    issue(100)
    first = pay("source", 100)
    latest = pay("source", 60)

    submit([
      open("source", [100, 100, 100]),
      open("destination", [30, 50, 100]),
      first,
      apply_credit("source", 80),
      latest,
      op("cancel_rooms", %{"group_id" => "destination", "room_ids" => ["r0"]})
    ])

    before = ledger()

    operation =
      transfer("source", "destination", 130, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 2
      })

    result = apply!(operation)

    assert %{
             "source_revision" => 5,
             "destination_revision" => 3,
             "source_outstanding_deposit_cents" => 190,
             "destination_outstanding_deposit_cents" => 20
           } = result

    assert Enum.map(group("source")["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) ==
             [{100, 0}, {0, 10}, {0, 0}]

    assert Enum.map(
             group("destination")["rooms"],
             &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
           ) == [{0, 0}, {50, 0}, {10, 70}]

    assert ledger() == before

    assert statement(latest)["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 60}
           ]

    refute Map.has_key?(statement(first), "held_by_group")
    assert credit()["available_cents"] == 30
    after_transfer = snapshot()
    assert submit(operation) == [result]
    assert read("operations/#{operation["operation_id"]}") == result
    assert snapshot() == after_transfer
    reject!(Map.put(operation, "amount_cents", 129), "operation_id_conflict")
    apply!(cancel("destination"))
    assert credit()["available_cents"] == 100
    assert statement(latest)["held_by_group"] == []
    assert statement(latest)["refunded_cents"] == 60
  end

  test "multi-hop transfers and corrections follow current allocation order across groups" do
    payment = pay("original", 200)

    [_, original_result | _] =
      submit([
        open("original"),
        payment,
        open("a"),
        open("z"),
        transfer("original", "a", 120),
        transfer("a", "z", 40),
        transfer("original", "z", 30)
      ])

    assert statement(payment)["held_by_group"] == [
             %{"group_id" => "a", "amount_cents" => 80},
             %{"group_id" => "original", "amount_cents" => 50},
             %{"group_id" => "z", "amount_cents" => 70}
           ]

    revisions = Map.new(~w(original a z), &{&1, group(&1)["revision"]})
    reduction = reduce(payment, 80, %{"expected_revision" => revisions["original"]})
    result = apply!(reduction)
    assert result["revision"] == revisions["original"] + 1
    assert result["outstanding_deposit_cents"] == 150
    assert Enum.map(group("a")["rooms"], & &1["cash_paid_cents"]) == [70, 0]
    assert group("z")["cash_paid_cents"] == 0
    for id <- ~w(original a z), do: assert(group(id)["revision"] == revisions[id] + 1)
    assert ledger()["cash_reduced_cents"] == 80
    assert submit(payment) == [original_result]
    before = snapshot()
    assert submit(reduction) == [result]
    assert snapshot() == before
    z_before = group("z")
    apply!(charge(payment))
    assert group("z") == z_before
    assert statement(payment)["held_by_group"] == []
    assert statement(payment)["charged_back_cents"] == 120
    assert ledger()["cash_held_cents"] == 0
  end

  test "a cancelled original group remains addressed while only destination funding is reduced" do
    payment = pay("original", 100)

    submit([
      open("original"),
      payment,
      open("destination"),
      transfer("original", "destination", 100),
      cancel("original")
    ])

    assert group("original")["revision"] == 4
    reject!(reduce(payment, 1, %{"expected_revision" => 3}), "stale_revision")

    assert %{"revision" => 5, "outstanding_deposit_cents" => 0} =
             apply!(reduce(payment, 100, %{"expected_revision" => 4}))

    assert group("destination")["revision"] == 3
    assert statement(payment)["held_by_group"] == []
    reject!(charge(payment), "payment_not_chargeable")
  end

  test "chargeback reclassifies settlements in each destination and revokes its converted entitlement" do
    payment = pay("source", 400)

    submit([
      open("source", [400]),
      payment,
      open("refund", [100]),
      open("retain", [100], %{"rate_plan" => "advance_purchase"}),
      open("convert", [100]),
      open("held", [100]),
      open("credit-user", [100])
    ])

    for destination <- ~w(refund retain convert held),
        do: apply!(transfer("source", destination, 100))

    submit([
      cancel("refund"),
      cancel("retain"),
      cancel("convert", %{"refund_method" => "hotel_credit"}),
      apply_credit("credit-user", 100),
      reduce(payment, 10)
    ])

    before_credit_user = group("credit-user")
    revisions = Map.new(~w(source refund retain convert held), &{&1, group(&1)["revision"]})
    result = apply!(charge(payment))
    assert result["charged_back_cents"] == 390

    for id <- ~w(source refund retain convert held),
        do: assert(group(id)["revision"] == revisions[id] + 1)

    assert group("credit-user") == before_credit_user

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 10,
             "cash_charged_back_cents" => 390,
             "credit_shortfall_cents" => 100,
             "credit_liability_cents" => 100
           } = ledger()

    assert statement(payment)["held_by_group"] == []
    apply!(cancel("credit-user"))
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert credit()["available_cents"] == 0

    for g <- Repo.all(Group),
        do:
          assert(
            g.cash_refunded_cents >= 0 and g.cash_retained_cents >= 0 and
              g.cash_converted_to_credit_cents >= 0
          )
  end

  test "transferred credit stays applied past expiry and restores to its original lot without a bonus" do
    issue(100)
    submit([open("source"), open("destination"), apply_credit("source", 100)])
    before = ledger("2027-11-02")
    apply!(transfer("source", "destination", 100, %{"occurred_on" => "2027-11-02"}))
    assert ledger("2027-11-02") == before
    assert before["credit_liability_cents"] == 100
    assert credit("2027-11-02")["available_cents"] == 0

    result =
      apply!(
        cancel("destination", %{"occurred_on" => "2027-11-02", "refund_method" => "hotel_credit"})
      )

    assert result["credit_issued_cents"] == 0
    assert ledger("2027-11-02")["credit_liability_cents"] == 0
    assert Repo.all(CreditAllocation) == []
  end

  test "transfers preserve shortfall absorption and non-refundable credit consumption" do
    payment = issue(100)

    submit([
      open("source"),
      open("destination", [50, 50]),
      apply_credit("source", 100),
      charge(payment)
    ])

    before = ledger()
    apply!(transfer("source", "destination", 100))
    assert ledger() == before
    apply!(op("cancel_rooms", %{"group_id" => "destination", "room_ids" => ["r0"]}))
    assert ledger()["credit_shortfall_cents"] == 50
    assert credit()["available_cents"] == 0
    apply!(cancel("destination", %{"occurred_on" => "2028-02-29"}))
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert [%{unrecovered_clawback_cents: 50}] = Repo.all(CreditLot)
  end

  test "transferred credit keeps multiple original lots and merges with existing destination credit" do
    for id <- ~w(first second) do
      submit([
        open(id, [50]),
        pay(id, 50),
        cancel(id, %{"operation_id" => "lot-#{id}", "refund_method" => "hotel_credit"})
      ])
    end

    submit([
      open("source"),
      open("destination"),
      apply_credit("source", 80),
      apply_credit("destination", 20)
    ])

    before = ledger()
    apply!(transfer("source", "destination", 70))
    assert ledger() == before
    assert credit()["available_cents"] == 10
    assert group("source")["credit_paid_cents"] == 10
    assert group("destination")["credit_paid_cents"] == 90

    # The newest source lot moves first, followed by a partial draw from the first lot.
    lots = Map.new(Repo.all(CreditLot), &{&1.id, &1.source_operation_id})
    held = GroupStay.RoomAccounting.held("destination")

    assert Enum.map(held, &{lots[&1.credit_lot_id], &1.amount_cents}) ==
             [{"lot-second", 20}, {"lot-second", 25}, {"lot-first", 45}]

    apply!(cancel("destination"))

    assert Enum.map(credit()["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) ==
             [{"lot-first", 45}, {"lot-second", 55}]

    apply!(cancel("source", %{"refund_method" => "hotel_credit"}))
    assert Enum.map(credit()["lots"], & &1["remaining_cents"]) == [55, 55]
    assert Repo.all(CreditAllocation) == []
    assert ledger()["credit_liability_cents"] == 110
  end

  test "existence and both revisions precede domain validation and rejections are atomic and durable" do
    submit([open("source"), open("destination"), pay("source", 100)])

    assert %{"group_id" => "missing-source"} =
             reject!(transfer("missing-source", "missing-destination", 1), "group_not_found")

    assert %{"group_id" => "missing"} =
             reject!(
               transfer("source", "missing", 1, %{"expected_revision" => 0}),
               "group_not_found"
             )

    assert %{"group_id" => "source", "expected_revision" => 0, "actual_revision" => 2} =
             reject!(
               transfer("source", "destination", 0, %{
                 "expected_revision" => 0,
                 "destination_expected_revision" => 0
               }),
               "stale_revision"
             )

    stale =
      transfer("source", "destination", -1, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 0
      })

    rejected = reject!(stale, "stale_revision")

    assert %{"group_id" => "destination", "expected_revision" => 0, "actual_revision" => 1} =
             rejected

    for value <- [nil, "1", 1.0, %{}],
        do:
          reject!(
            transfer("source", "destination", 1, %{"destination_expected_revision" => value}),
            "stale_revision"
          )

    reject!(transfer("source", "source", 1), "invalid_transfer")

    for amount <- [0, -1, nil, 1.5, "1", true],
        do: reject!(transfer("source", "destination", amount), "invalid_amount")

    reject!(transfer("source", "destination", 101), "transfer_exceeds_held_funding")
    apply!(pay("destination", 150))
    reject!(transfer("source", "destination", 51), "transfer_exceeds_outstanding")
    assert submit(stale) == [rejected]
    reject!(Map.put(stale, "destination_expected_revision", 2), "operation_id_conflict")
    apply!(open("other", [100], %{"guest_id" => "other"}))
    reject!(transfer("source", "other", 1), "invalid_transfer")
    apply!(cancel("source"))

    assert %{"group_id" => "source"} =
             reject!(transfer("source", "destination", 1), "group_not_active")

    assert %{"group_id" => "source"} =
             reject!(transfer("destination", "source", 1), "group_not_active")
  end

  test "malformed transfers reject and same-batch operations see both new revisions" do
    submit([open("source"), open("destination"), pay("source", 100)])

    for field <- ~w(source_group_id destination_group_id occurred_on amount_cents),
        do: reject!(Map.delete(transfer("source", "destination", 1), field), "invalid_operation")

    for field <- ~w(source_group_id destination_group_id),
        value <- [nil, "", 42, %{}],
        do:
          reject!(
            Map.put(transfer("source", "destination", 1), field, value),
            "invalid_operation"
          )

    assert [
             %{"status" => "applied", "source_revision" => 3, "destination_revision" => 2},
             %{"code" => "stale_revision", "actual_revision" => 2},
             %{"status" => "applied", "source_revision" => 3, "destination_revision" => 4}
           ] =
             submit([
               transfer("source", "destination", 60),
               transfer("destination", "source", 20, %{"expected_revision" => 1}),
               transfer("destination", "source", 60, %{
                 "expected_revision" => 2,
                 "destination_expected_revision" => 3
               })
             ])

    assert group("source")["cash_paid_cents"] == 100
    assert group("destination")["cash_paid_cents"] == 0
  end
end
