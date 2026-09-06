defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    FundingAllocation,
    Group,
    Operation,
    Operations,
    Repo,
    Reservations
  }

  defp open(id, dues \\ [100, 100, 100], extra \\ %{}) do
    op(
      "open_group",
      id,
      Map.merge(
        %{
          "guest_id" => "guest",
          "property_id" => "hotel",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02",
          "rate_plan" => "flexible",
          "rooms" =>
            Enum.with_index(dues, fn due, index ->
              %{"room_id" => "room-#{index}", "nightly_rate_cents" => due * 5}
            end)
        },
        extra
      )
    )
  end

  defp op(type, group, fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "group_id" => group,
        "occurred_on" => "2026-11-01"
      },
      fields
    )
  end

  defp pay(group, amount), do: op("record_cash_payment", group, %{"amount_cents" => amount})

  defp cancel(group, ids, fields \\ %{}),
    do: op("cancel_rooms", group, Map.put(fields, "room_ids", ids))

  defp reduce(payment, amount, fields \\ %{}),
    do: target("reduce_cash_payment", payment, Map.put(fields, "amount_cents", amount))

  defp charge(payment, fields \\ %{}), do: target("charge_back_payment", payment, fields)

  defp target(type, payment, fields) do
    op(type, nil, Map.put(fields, "payment_operation_id", payment["operation_id"]))
    |> Map.delete("group_id")
  end

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

  defp group(id),
    do: build_conn() |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp statement(payment) do
    result =
      build_conn()
      |> get("/api/v1/payments/#{payment["operation_id"]}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.sort(Map.keys(result)) ==
             Enum.sort(
               ~w(payment_operation_id original_group_id recorded_cents held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
             )

    assert result["recorded_cents"] ==
             Enum.sum(
               for key <-
                     ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                   do: result[key]
             )

    result
  end

  defp ledger(on \\ "2026-11-01"),
    do: build_conn() |> get("/api/v1/ledger?on=#{on}") |> json_response(200) |> Map.fetch!("data")

  defp credit(on \\ ~D[2026-11-01]), do: Reservations.guest_credit("guest", on)

  defp snapshot,
    do:
      Enum.map(
        [Group, CreditLot, CreditAllocation, FundingAllocation, CreditEntitlement],
        &Repo.all/1
      )

  defp reject!(operation, code) do
    before = snapshot()
    assert [%{"status" => "rejected", "code" => ^code}] = submit(operation)
    assert snapshot() == before
  end

  defp issue(amount) do
    id = "source-#{System.unique_integer([:positive])}"
    payment = pay(id, amount)
    submit([open(id, [amount]), payment])
    cancellation = op("cancel_group", id, %{"refund_method" => "hotel_credit"})
    apply!(cancellation)
    {payment, cancellation}
  end

  test "mixed funding fills rooms in processing order and selected settlement leaves other rooms intact" do
    issue(200)
    payment = pay("group", 150)
    submit([open("group"), payment, op("apply_hotel_credit", "group", %{"amount_cents" => 120})])
    before = group("group")

    assert Enum.map(before["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {100, 0},
             {50, 50},
             {0, 70}
           ]

    result = apply!(cancel("group", ["room-1"]))

    assert %{
             "cancelled_room_ids" => ["room-1"],
             "refunded_cents" => 50,
             "credit_issued_cents" => 0,
             "revision" => 4
           } = result

    after_cancel = group("group")
    assert Enum.at(after_cancel["rooms"], 0) == Enum.at(before["rooms"], 0)
    assert Enum.at(after_cancel["rooms"], 2) == Enum.at(before["rooms"], 2)

    assert %{
             "lodging_total_cents" => 1000,
             "deposit_due_cents" => 200,
             "deposit_paid_cents" => 170,
             "outstanding_deposit_cents" => 30,
             "status" => "active"
           } = after_cancel

    assert credit().available_cents == 150
    assert statement(payment)["refunded_cents"] == 50
    apply!(reduce(payment, 80))
    assert Enum.map(group("group")["rooms"], & &1["cash_paid_cents"]) == [20, 0, 0]
    apply!(pay("group", 100))
    assert Enum.map(group("group")["rooms"], & &1["cash_paid_cents"]) == [100, 0, 20]
    final = apply!(op("cancel_group", "group"))
    assert final["refunded_cents"] == 120
    assert group("group")["lodging_total_cents"] == 0
    assert group("group")["status"] == "cancelled"
    assert credit().available_cents == 220
  end

  test "selected rooms use original order and receive one half-up bonus on combined cash" do
    payment = pay("group", 10)
    submit([open("group", [5, 5, 5]), payment])
    result = apply!(cancel("group", ["room-1", "room-0"], %{"refund_method" => "hotel_credit"}))
    assert %{"cancelled_room_ids" => ["room-0", "room-1"], "credit_issued_cents" => 11} = result
    assert credit().available_cents == 11
    assert statement(payment)["converted_to_credit_cents"] == 10
    apply!(cancel("group", ["room-2"]))
    assert group("group")["status"] == "cancelled"
  end

  test "reductions compose in reverse fill order and retries keep original revisions and balances" do
    first = pay("group", 150)
    second = pay("group", 100)
    [_, original, _] = submit([open("group"), first, second])
    reduction = reduce(first, 60, %{"expected_revision" => 3})
    result = apply!(reduction)
    assert %{"revision" => 4, "outstanding_deposit_cents" => 110} = result
    assert Enum.map(group("group")["rooms"], & &1["cash_paid_cents"]) == [90, 50, 50]
    assert submit(first) == [original]
    assert submit(reduction) == [result]
    reject!(reduce(first, 91), "reduction_exceeds_held_cash")
    reject!(reduce(first, 0), "invalid_amount")
    reject!(reduce(first, 1.5), "invalid_amount")
    reject!(reduce(first, "1"), "invalid_amount")
    apply!(reduce(first, 40))
    apply!(reduce(first, 50))
    reject!(reduce(first, 1), "payment_not_reducible")
    reject!(charge(first), "payment_not_chargeable")
    assert statement(first)["reduced_cents"] == 150
    assert statement(second)["held_cents"] == 100
    assert ledger()["cash_reduced_cents"] == 150
    reject!(Map.put(reduction, "amount_cents", 1), "operation_id_conflict")
  end

  test "chargeback reclassifies held, refunded, retained and converted cash while preserving reductions" do
    payment = pay("group", 400)
    [_, original] = submit([open("group", [100, 100, 100, 100]), payment])
    refunded = cancel("group", ["room-0"])
    retained = cancel("group", ["room-1"], %{"occurred_on" => "2027-02-16"})
    converted = cancel("group", ["room-2"], %{"refund_method" => "hotel_credit"})
    settlements = submit([refunded, retained, converted, reduce(payment, 50)])

    assert %{
             "held_cents" => 50,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 100,
             "reduced_cents" => 50,
             "charged_back_cents" => 0
           } = statement(payment)

    operation = charge(payment, %{"expected_revision" => 6})
    result = apply!(operation)

    assert %{"charged_back_cents" => 350, "revision" => 7, "outstanding_deposit_cents" => 100} =
             result

    assert %{
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 50,
             "charged_back_cents" => 350
           } = statement(payment)

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 50,
             "cash_charged_back_cents" => 350,
             "credit_liability_cents" => 0
           } = ledger()

    assert credit().available_cents == 0
    assert submit(operation) == [result]
    assert submit(payment) == [original]
    assert submit([refunded, retained, converted]) == Enum.take(settlements, 3)
    reject!(charge(payment), "payment_not_chargeable")
    reject!(charge(payment, %{"expected_revision" => 6}), "stale_revision")
    apply!(pay("group", 100))
    assert group("group")["deposit_paid_cents"] == 100
  end

  test "lot entitlements telescope in payment funding order with half-up rounding" do
    payments = for amount <- [4, 1, 5], do: pay("group", amount)
    submit([open("group", [5, 5]) | payments])
    apply!(op("cancel_group", "group", %{"refund_method" => "hotel_credit"}))
    assert credit().available_cents == 11
    assert Enum.map(Repo.all(CreditEntitlement), & &1.amount_cents) == [4, 2, 5]
    apply!(charge(Enum.at(payments, 1)))
    assert credit().available_cents == 9
    apply!(charge(Enum.at(payments, 0)))
    assert credit().available_cents == 5
    apply!(charge(Enum.at(payments, 2)))
    assert credit().available_cents == 0
    assert group("group")["status"] == "cancelled"
    assert group("group")["revision"] == 8
  end

  test "a payment contributes independently rounded entitlements to multiple lots" do
    payment = pay("group", 10)
    submit([open("group", [5, 5]), payment])

    for id <- ~w(room-0 room-1),
        do: apply!(cancel("group", [id], %{"refund_method" => "hotel_credit"}))

    assert credit().available_cents == 12
    assert length(Repo.all(CreditEntitlement)) == 2
    apply!(charge(payment))
    assert credit().available_cents == 0
    assert statement(payment)["charged_back_cents"] == 10
  end

  test "spent credit creates shortfall without changing funded groups and restorations absorb it" do
    {payment, _} = issue(100)

    submit([
      open("target", [40, 40]),
      op("apply_hotel_credit", "target", %{"amount_cents" => 80})
    ])

    target_before = group("target")
    apply!(charge(payment))
    assert group("target") == target_before
    assert credit().available_cents == 0
    assert %{"credit_shortfall_cents" => 80, "credit_liability_cents" => 80} = ledger()
    apply!(cancel("target", ["room-0"]))
    assert credit().available_cents == 0
    assert %{"credit_shortfall_cents" => 40, "credit_liability_cents" => 40} = ledger()
    apply!(cancel("target", ["room-1"], %{"occurred_on" => "2027-02-16"}))
    assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0} = ledger()
    assert [%{unrecovered_clawback_cents: 40}] = Repo.all(CreditLot)
  end

  test "fungible spending and partial entitlement revocation restore excess credit after absorption" do
    first = pay("source", 50)
    second = pay("source", 50)

    submit([
      open("source", [100]),
      first,
      second,
      op("cancel_group", "source", %{"refund_method" => "hotel_credit"}),
      open("target", [80]),
      op("apply_hotel_credit", "target", %{"amount_cents" => 80})
    ])

    apply!(charge(first))
    assert %{"credit_shortfall_cents" => 25, "credit_liability_cents" => 80} = ledger()
    apply!(op("cancel_group", "target"))
    assert credit().available_cents == 55
    assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 55} = ledger()
    assert statement(second)["converted_to_credit_cents"] == 50
    apply!(charge(second))
    assert credit().available_cents == 0
  end

  test "shortfall absorption precedes expiry and exhausted shortfall remains capped by active credit" do
    first = pay("source", 50)
    second = pay("source", 50)

    submit([
      open("source", [100]),
      first,
      second,
      op("cancel_group", "source", %{"refund_method" => "hotel_credit"}),
      open("target", [80], %{"arrival_on" => "2028-03-01", "departure_on" => "2028-03-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 80})
    ])

    apply!(charge(first))

    assert %{"credit_shortfall_cents" => 25, "credit_liability_cents" => 80} =
             ledger("2027-11-02")

    apply!(op("cancel_group", "target", %{"occurred_on" => "2027-11-02"}))
    assert [%{remaining_cents: 0, unrecovered_clawback_cents: 0}] = Repo.all(CreditLot)
    assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0} = ledger("2027-11-02")
    apply!(charge(second))
    assert [%{unrecovered_clawback_cents: 55}] = Repo.all(CreditLot)
    assert ledger("2027-11-02")["credit_shortfall_cents"] == 0
  end

  test "room validation and revision precedence reject atomically and persist rejections" do
    opening = open("group")
    payment = pay("group", 150)
    submit([opening, payment])

    for ids <- [nil, [], "room-0", ["room-0", "room-0"], ["room-0", "missing"], [nil], [%{}]] do
      reject!(cancel("group", ids), "invalid_rooms")
    end

    reject!(cancel("group", [], %{"expected_revision" => 1}), "stale_revision")

    reject!(
      cancel("group", ["room-0"], %{
        "refund_method" => "hotel_credit",
        "occurred_on" => "2027-02-16"
      }),
      "refund_method_not_available"
    )

    reject!(cancel("group", ["room-0"], %{"refund_method" => "bad"}), "invalid_operation")
    reject!(op("cancel_rooms", "group"), "invalid_operation")
    reject!(Map.delete(reduce(payment, 1), "amount_cents"), "invalid_operation")

    for correction <- [reduce(payment, 1), charge(payment)],
        field <- ~w(payment_operation_id occurred_on) do
      malformed =
        correction
        |> Map.delete(field)
        |> Map.put("operation_id", "malformed-#{System.unique_integer([:positive])}")

      reject!(malformed, "invalid_operation")
    end

    cancellation = cancel("group", ["room-0"])
    result = apply!(cancellation)
    assert submit(cancellation) == [result]
    reject!(cancel("group", ["room-0", "room-1"]), "invalid_rooms")
    stale = reduce(payment, -1, %{"expected_revision" => 2})
    [rejection] = submit(stale)

    assert %{"code" => "stale_revision", "actual_revision" => 3, "group_id" => "group"} =
             rejection

    apply!(reduce(payment, 10))
    assert submit(stale) == [rejection]
    reject!(Map.put(stale, "expected_revision", 4), "operation_id_conflict")
    reject!(charge(opening, %{"expected_revision" => 1}), "stale_revision")
    reject!(reduce(opening, 1), "payment_not_reducible")
  end

  test "payment lookup distinguishes missing and non-payment records and reads never write" do
    opening = open("group")
    rejected = pay("group", 999)
    payment = pay("group", 20)
    submit([opening, rejected, payment])

    for record <- [opening, rejected] do
      assert build_conn()
             |> get("/api/v1/payments/#{record["operation_id"]}")
             |> json_response(422) ==
               %{"error" => %{"code" => "payment_not_reconcilable"}}

      reject!(charge(record), "payment_not_chargeable")
      reject!(reduce(record, 1), "payment_not_reducible")
    end

    missing = %{"operation_id" => "legacy-payment"}

    assert build_conn() |> get("/api/v1/payments/legacy-payment") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}

    reject!(charge(missing), "operation_not_found")
    reject!(reduce(missing, 1), "operation_not_found")
    before = snapshot()
    records = Repo.all(Operation)
    assert statement(payment)["held_cents"] == 20
    ledger("2099-01-01")
    credit(~D[2099-01-01])
    assert snapshot() == before
    assert Repo.all(Operation) == records
    assert Operations.get(payment["operation_id"])["revision"] == 2
  end

  test "shortfall is capped separately per lot when another lot still funds active rooms" do
    first = pay("source-a", 100)
    second = pay("source-z", 100)

    submit([
      open("source-a", [100]),
      first,
      op("cancel_group", "source-a", %{
        "operation_id" => "lot-a",
        "refund_method" => "hotel_credit"
      }),
      open("source-z", [100]),
      second,
      op("cancel_group", "source-z", %{
        "operation_id" => "lot-z",
        "refund_method" => "hotel_credit"
      }),
      open("target-a", [100]),
      op("apply_hotel_credit", "target-a", %{"amount_cents" => 100}),
      open("target-b", [110]),
      op("apply_hotel_credit", "target-b", %{"amount_cents" => 110})
    ])

    apply!(charge(first))
    assert %{"credit_shortfall_cents" => 110, "credit_liability_cents" => 220} = ledger()
    apply!(op("cancel_group", "target-a", %{"occurred_on" => "2027-02-16"}))
    assert %{"credit_shortfall_cents" => 10, "credit_liability_cents" => 120} = ledger()
    apply!(charge(second))
    assert %{"credit_shortfall_cents" => 110, "credit_liability_cents" => 110} = ledger()
    apply!(op("cancel_group", "target-b"))
    assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0} = ledger()
    assert credit().available_cents == 0
  end
end
