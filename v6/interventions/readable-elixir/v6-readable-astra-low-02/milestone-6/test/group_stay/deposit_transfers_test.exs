defmodule GroupStay.DepositTransfersTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Reservations.{CashAllocation, CreditAllocation, CreditLot, Group, Payments}

  defp op(type, id, attrs) do
    Map.merge(%{"type" => type, "operation_id" => id, "occurred_on" => "2027-01-01"}, attrs)
  end

  defp apply_op(type, id, attrs) do
    [result] = Reservations.submit([op(type, id, attrs)])
    result
  end

  defp open(id, attrs \\ %{}) do
    apply_op(
      "open_group",
      "open-#{id}",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => id,
          "arrival_on" => "2029-06-01",
          "departure_on" => "2029-06-02",
          "rate_plan" => "flexible",
          "rooms" => Enum.map(1..3, &%{"room_id" => "r#{&1}", "nightly_rate_cents" => 500})
        },
        attrs
      )
    )
  end

  defp pay(id, group, amount),
    do: apply_op("record_cash_payment", id, %{"group_id" => group, "amount_cents" => amount})

  defp transfer(id, source, destination, amount, attrs \\ %{}),
    do:
      apply_op(
        "transfer_deposit",
        id,
        Map.merge(
          %{
            "source_group_id" => source,
            "destination_group_id" => destination,
            "amount_cents" => amount
          },
          attrs
        )
      )

  defp statement(id) do
    {:ok, statement} = Payments.statement(id)
    statement
  end

  defp snapshot do
    Enum.map([Group, CashAllocation, CreditAllocation, CreditLot], &Repo.all/1)
  end

  test "mixed funding moves newest allocations first, preserving draw order, lots, and cash identity" do
    open("issuer")
    pay("issue-payment", "issuer", 100)

    apply_op("cancel_group", "issue", %{"group_id" => "issuer", "refund_method" => "hotel_credit"})

    open("a")
    open("b")
    original = pay("first", "a", 70)
    apply_op("apply_hotel_credit", "credit", %{"group_id" => "a", "amount_cents" => 110})
    pay("last", "a", 60)
    ledger = Reservations.ledger(~D[2028-02-01])

    assert %{
             source_revision: 5,
             destination_revision: 2,
             source_outstanding_deposit_cents: 210,
             destination_outstanding_deposit_cents: 150
           } =
             result = transfer("move", "a", "b", 150, %{"occurred_on" => "2028-02-01"})

    assert Enum.map(
             Reservations.get_group("b").rooms,
             &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
           ) ==
             [{60, 40}, {0, 50}, {0, 0}]

    assert Reservations.ledger(~D[2028-02-01]) == ledger
    assert statement("last").held_by_group == [%{group_id: "b", amount_cents: 60}]
    refute Map.has_key?(statement("first"), :held_by_group)
    assert transfer("move", "a", "b", 150, %{"occurred_on" => "2028-02-01"}) == result
    assert pay("first", "a", 70) == original

    # A second transfer takes the newly created destination allocations first.
    transfer("return", "b", "a", 50)
    assert Reservations.get_group("a").credit_paid_cents == 70
    apply_op("cancel_group", "expired", %{"group_id" => "b", "occurred_on" => "2028-02-01"})
    assert statement("last").held_by_group == []
    assert statement("last").refunded_cents == 60
    assert Reservations.ledger(~D[2028-02-01]).credit_liability_cents == 70
  end

  test "corrections follow global allocation order and revise only affected groups plus the original" do
    for id <- ["a", "b", "c"], do: open(id)
    original = pay("p", "a", 250)
    transfer("ab", "a", "b", 120)
    transfer("bc", "b", "c", 40)

    assert %{revision: 4, outstanding_deposit_cents: 170} =
             apply_op("reduce_cash_payment", "reduce", %{
               "payment_operation_id" => "p",
               "amount_cents" => 60,
               "expected_revision" => 3
             })

    assert Enum.map(["a", "b", "c"], &Reservations.get_group(&1).revision) == [4, 4, 3]

    assert statement("p").held_by_group ==
             [%{group_id: "a", amount_cents: 130}, %{group_id: "b", amount_cents: 60}]

    assert %{revision: 5, charged_back_cents: 190, outstanding_deposit_cents: 300} =
             apply_op("charge_back_payment", "charge", %{
               "payment_operation_id" => "p",
               "expected_revision" => 4
             })

    assert Enum.map(["a", "b", "c"], &Reservations.get_group(&1).revision) == [5, 5, 3]
    assert statement("p").held_by_group == []
    assert statement("p").reduced_cents == 60
    assert pay("p", "a", 250) == original

    assert %{cash_reduced_cents: 60, cash_charged_back_cents: 190, cash_held_cents: 0} =
             Reservations.ledger()
  end

  test "existence and both revision guards precede transfer rules and rejections are durable" do
    open("a")
    open("b", %{"guest_id" => "other"})
    open("c")
    pay("p", "a", 100)
    apply_op("cancel_group", "cancel", %{"group_id" => "c"})
    before = snapshot()

    assert %{code: "group_not_found", group_id: "missing"} =
             transfer("missing-source", "missing", "absent", 1)

    assert %{code: "group_not_found", group_id: "absent"} =
             transfer("missing-dest", "a", "absent", 1, %{"expected_revision" => 0})

    assert %{code: "stale_revision", group_id: "a", actual_revision: 2} =
             transfer("stale-source", "a", "b", -1, %{
               "expected_revision" => 1,
               "destination_expected_revision" => 0
             })

    assert %{code: "stale_revision", group_id: "b", expected_revision: 0, actual_revision: 1} =
             transfer("stale-dest", "a", "b", -1, %{
               "expected_revision" => 2,
               "destination_expected_revision" => 0
             })

    assert %{code: "invalid_transfer"} = transfer("same", "a", "a", 1)
    assert %{code: "invalid_transfer"} = transfer("guest", "a", "b", 1)
    assert %{code: "group_not_active", group_id: "c"} = transfer("inactive", "a", "c", 1)
    assert snapshot() == before

    open("d")

    for {amount, index} <- Enum.with_index([0, -1, nil, "1", 1.5]) do
      assert %{code: "invalid_amount"} = transfer("bad-#{index}", "a", "d", amount)
    end

    assert %{code: "transfer_exceeds_held_funding"} =
             rejected = transfer("too-much", "a", "d", 101)

    pay("more", "a", 100)
    assert transfer("too-much", "a", "d", 101) == rejected
    assert %{code: "operation_id_conflict"} = transfer("too-much", "a", "d", 100)
    pay("dest-pay", "d", 250)
    assert %{code: "transfer_exceeds_outstanding"} = transfer("no-space", "a", "d", 51)
  end

  test "transferred cash converts under destination policy and clawback follows its entitlement" do
    open("a", %{"rate_plan" => "advance_purchase"})
    open("b")
    open("c")
    pay("p", "a", 100)
    transfer("move", "a", "b", 100)

    assert %{credit_issued_cents: 110} =
             apply_op("cancel_group", "convert", %{
               "group_id" => "b",
               "refund_method" => "hotel_credit"
             })

    apply_op("apply_hotel_credit", "use", %{"group_id" => "c", "amount_cents" => 110})
    open("d")
    transfer("credit-move", "c", "d", 110)
    d = Reservations.get_group("d")
    apply_op("charge_back_payment", "charge", %{"payment_operation_id" => "p"})
    assert Reservations.get_group("d") == d

    assert %{credit_shortfall_cents: 110, credit_liability_cents: 110} =
             Reservations.ledger(~D[2027-01-01])

    apply_op("cancel_group", "restore", %{"group_id" => "d"})

    assert %{credit_shortfall_cents: 0, credit_liability_cents: 0} =
             Reservations.ledger(~D[2027-01-01])
  end

  test "HTTP batches see transfers immediately and audit failure rolls back both groups and provenance" do
    open("a")
    open("b")
    pay("p", "a", 100)

    move =
      op("transfer_deposit", "move", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 100
      })

    before = snapshot()

    Repo.query!(
      "CREATE TRIGGER fail_transfer BEFORE INSERT ON partner_operations WHEN NEW.operation_id = 'move' BEGIN SELECT RAISE(ABORT, 'fault'); END"
    )

    assert_error_sent 500, fn ->
      build_conn() |> post("/api/v1/partner-batches", %{"operations" => [move]})
    end

    assert snapshot() == before
    refute Map.has_key?(statement("p"), :held_by_group)
    assert Operations.get_result("move") == nil
    Repo.query!("DROP TRIGGER fail_transfer")

    correction =
      op("reduce_cash_payment", "reduce", %{
        "payment_operation_id" => "p",
        "amount_cents" => 100,
        "expected_revision" => 3
      })

    response =
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => [move, correction]})
      |> json_response(200)

    assert [%{"source_revision" => 3, "destination_revision" => 2}, %{"revision" => 4}] =
             response["results"]

    assert build_conn()
           |> post("/api/v1/partner-batches", %{"operations" => [move, correction]})
           |> json_response(200) == response

    assert build_conn()
           |> get("/api/v1/payments/p")
           |> json_response(200)
           |> get_in(["data", "held_by_group"]) == []
  end
end
