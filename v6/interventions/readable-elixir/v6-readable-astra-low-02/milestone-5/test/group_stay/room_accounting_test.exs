defmodule GroupStay.RoomAccountingTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Operations, Repo, Reservations}

  alias GroupStay.Reservations.{
    CashAllocation,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    Payments
  }

  defp open(id, rates \\ [500, 500, 500], attrs \\ %{}) do
    apply_op(
      "open_group",
      "open-#{id}",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => "hotel",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02",
          "rate_plan" => "flexible",
          "rooms" =>
            rates
            |> Enum.with_index()
            |> Enum.map(fn {rate, i} -> %{"room_id" => "r#{i}", "nightly_rate_cents" => rate} end)
        },
        attrs
      )
    )
  end

  defp operation(type, id, attrs) do
    Map.merge(%{"type" => type, "operation_id" => id, "occurred_on" => "2027-01-01"}, attrs)
  end

  defp apply_op(type, id, attrs) do
    [result] = Reservations.submit([operation(type, id, attrs)])
    result
  end

  defp pay(id, group, amount),
    do: apply_op("record_cash_payment", id, %{"group_id" => group, "amount_cents" => amount})

  defp cancel(id, group, rooms, attrs \\ %{}),
    do:
      apply_op("cancel_rooms", id, Map.merge(%{"group_id" => group, "room_ids" => rooms}, attrs))

  defp reduce(id, payment, amount, attrs \\ %{}),
    do:
      apply_op(
        "reduce_cash_payment",
        id,
        Map.merge(%{"payment_operation_id" => payment, "amount_cents" => amount}, attrs)
      )

  defp charge(id, payment, attrs \\ %{}),
    do:
      apply_op("charge_back_payment", id, Map.merge(%{"payment_operation_id" => payment}, attrs))

  defp statement(id) do
    {:ok, result} = Payments.statement(id)

    assert result.recorded_cents ==
             result.held_cents + result.refunded_cents + result.retained_cents +
               result.converted_to_credit_cents + result.reduced_cents + result.charged_back_cents

    result
  end

  defp snapshot do
    Enum.map([Group, CashAllocation, CreditAllocation, CreditLot, CreditEntitlement], &Repo.all/1)
  end

  defp issue(id, amount) do
    open(id, [10000])
    pay("pay-#{id}", id, amount)

    apply_op("cancel_group", "issue-#{id}", %{"group_id" => id, "refund_method" => "hotel_credit"})
  end

  test "mixed funding fills in processing order and partial settlement leaves other rooms unchanged" do
    issue("source", 100)
    open("target")
    pay("first", "target", 70)
    apply_op("apply_hotel_credit", "credit", %{"group_id" => "target", "amount_cents" => 110})
    pay("last", "target", 60)
    [a, b, c] = Reservations.get_group("target").rooms
    assert {a["cash_paid_cents"], a["credit_paid_cents"]} == {70, 30}
    assert {b["cash_paid_cents"], b["credit_paid_cents"]} == {20, 80}
    assert {c["cash_paid_cents"], c["credit_paid_cents"]} == {40, 0}
    assert a["lodging_total_cents"] == 500
    assert a["deposit_due_cents"] == 100

    assert %{cancelled_room_ids: ["r0", "r2"], refunded_cents: 110, revision: 5} =
             cancel("partial", "target", ["r2", "r0"])

    group = Reservations.get_group("target")
    assert Enum.at(group.rooms, 1) == b

    assert {group.lodging_total_cents, group.deposit_due_cents, group.deposit_paid_cents,
            group.status} == {500, 100, 100, "active"}

    assert statement("first").refunded_cents == 70
    assert %{held_cents: 20, refunded_cents: 40} = statement("last")
    assert Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 30

    assert %{refunded_cents: 20, revision: 6} =
             apply_op("cancel_group", "rest", %{"group_id" => "target"})

    assert %{status: "cancelled", lodging_total_cents: 0, deposit_paid_cents: 0} =
             Reservations.get_group("target")

    assert Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 110
  end

  test "reductions target held cash in reverse fill order and new funding fills reopened space" do
    open("g")
    original = pay("p", "g", 250)

    assert %{amount_cents: 80, outstanding_deposit_cents: 130, revision: 3} =
             reduce("reduce", "p", 80)

    assert Enum.map(Reservations.get_group("g").rooms, & &1["cash_paid_cents"]) == [100, 70, 0]
    pay("new", "g", 90)
    assert Enum.map(Reservations.get_group("g").rooms, & &1["cash_paid_cents"]) == [100, 100, 60]
    cancel("cancel", "g", ["r0"])
    assert %{held_cents: 70, refunded_cents: 100, reduced_cents: 80} = statement("p")
    assert %{code: "reduction_exceeds_held_cash"} = reduce("too-big", "p", 71)
    assert %{revision: 6} = reduce("all-held", "p", 70)
    assert %{code: "payment_not_reducible"} = reduce("empty", "p", 1)
    assert pay("p", "g", 250) == original
    assert Operations.get_result("p") == original

    assert %{cash_reduced_cents: 150, cash_refunded_cents: 100, cash_held_cents: 90} =
             Reservations.ledger()
  end

  test "room validation and payment validation preserve domain state and check revisions first" do
    open("g")
    pay("p", "g", 100)
    before = snapshot()

    for {ids, i} <- Enum.with_index([[], ["r0", "r0"], ["r0", "missing"], nil, "r0", [1]]) do
      assert %{code: "invalid_rooms"} = cancel("invalid-#{i}", "g", ids)
    end

    assert %{code: "stale_revision", actual_revision: 2} =
             cancel("stale", "g", [], %{"expected_revision" => 1})

    assert %{code: "refund_method_not_available"} =
             cancel("late-credit", "g", ["r0"], %{
               "occurred_on" => "2027-05-03",
               "refund_method" => "hotel_credit"
             })

    for {amount, i} <- Enum.with_index([0, -1, 0.5, "1", nil]) do
      assert %{code: "invalid_amount"} = reduce("invalid-reduce-#{i}", "p", amount)
    end

    assert %{code: "stale_revision"} =
             reduce("stale-reduce", "p", -1, %{"expected_revision" => 1})

    assert %{code: "stale_revision"} = charge("stale-charge", "p", %{"expected_revision" => 1})
    assert %{code: "operation_not_found"} = reduce("missing", "legacy", 1)
    assert %{code: "payment_not_reducible"} = reduce("wrong", "open-g", 1)
    assert %{code: "payment_not_chargeable"} = charge("wrong-charge", "open-g")
    assert snapshot() == before
    cancel("cancel", "g", ["r0"])
    assert %{code: "invalid_rooms"} = cancel("again", "g", ["r0", "r1"])

    assert %{code: "stale_revision"} =
             reduce("settled-stale", "p", 1, %{"expected_revision" => 2})
  end

  test "chargebacks reclassify all dispositions except reductions and preserve exact results" do
    open("g", List.duplicate(500, 5))
    payment = pay("p", "g", 500)
    reduce("reduce", "p", 30)
    cancel("refund", "g", ["r0"])
    cancel("retain", "g", ["r1"], %{"occurred_on" => "2027-05-03"})
    cancel("convert", "g", ["r2"], %{"refund_method" => "hotel_credit"})

    assert %{
             held_cents: 170,
             refunded_cents: 100,
             retained_cents: 100,
             converted_to_credit_cents: 100,
             reduced_cents: 30
           } = statement("p")

    assert %{charged_back_cents: 470, outstanding_deposit_cents: 200, revision: 7} =
             result = charge("charge", "p")

    assert %{
             held_cents: 0,
             refunded_cents: 0,
             retained_cents: 0,
             converted_to_credit_cents: 0,
             reduced_cents: 30,
             charged_back_cents: 470
           } = statement("p")

    assert %{cash_charged_back_cents: 470, cash_reduced_cents: 30, credit_liability_cents: 0} =
             Reservations.ledger(~D[2027-01-01])

    assert charge("charge", "p") == result
    assert pay("p", "g", 500) == payment
    assert %{code: "payment_not_chargeable"} = charge("again", "p")
    assert %{code: "operation_id_conflict"} = charge("charge", "p", %{"expected_revision" => 7})
  end

  test "combined bonuses telescope by payment order separately for each lot" do
    open("g", [10, 15, 25])
    pay("z-first", "g", 2)
    pay("a-second", "g", 8)

    assert %{credit_issued_cents: 6, cancelled_room_ids: ["r0", "r1"]} =
             cancel("lot1", "g", ["r1", "r0"], %{"refund_method" => "hotel_credit"})

    assert %{credit_issued_cents: 6} =
             cancel("lot2", "g", ["r2"], %{"refund_method" => "hotel_credit"})

    assert %{charged_back_cents: 2} = charge("charge-first", "z-first")
    assert Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 10
    assert %{charged_back_cents: 8} = charge("charge-second", "a-second")
    assert Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 0
  end

  test "clawbacks consume unspent credit first, keep applied liability and absorb later restorations" do
    issue("source", 100)
    open("target", [250, 250])
    apply_op("apply_hotel_credit", "use", %{"group_id" => "target", "amount_cents" => 100})
    target_before = Reservations.get_group("target")
    assert %{charged_back_cents: 100, revision: 4} = charge("charge", "pay-source")
    assert Reservations.get_group("target") == target_before

    assert %{credit_shortfall_cents: 100, credit_liability_cents: 100} =
             Reservations.ledger(~D[2027-01-01])

    assert Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 0
    cancel("restore", "target", ["r0"])

    assert %{credit_shortfall_cents: 50, credit_liability_cents: 50} =
             Reservations.ledger(~D[2027-01-01])

    cancel("consume", "target", ["r1"], %{"occurred_on" => "2027-05-03"})

    assert %{credit_shortfall_cents: 0, credit_liability_cents: 0} =
             Reservations.ledger(~D[2027-01-01])
  end

  test "expired restoration absorbs clawback before expiry and fungible excess can return" do
    open("source", [1000])
    pay("first", "source", 50)
    pay("second", "source", 50)
    cancel("lot", "source", ["r0"], %{"refund_method" => "hotel_credit"})
    open("target", [250, 300], %{"arrival_on" => "2029-06-01", "departure_on" => "2029-06-02"})
    apply_op("apply_hotel_credit", "use", %{"group_id" => "target", "amount_cents" => 110})
    charge("charge", "first")

    assert %{credit_shortfall_cents: 55, credit_liability_cents: 110} =
             Reservations.ledger(~D[2027-01-01])

    cancel("expired", "target", ["r0"], %{"occurred_on" => "2028-01-02"})
    assert [%{unrecovered_clawback_cents: 5}] = Repo.all(CreditLot)
    cancel("unexpired", "target", ["r1"])

    assert %{credit_shortfall_cents: 0, credit_liability_cents: 55} =
             Reservations.ledger(~D[2027-01-01])

    assert Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 55
  end

  test "shortfall is capped by active credit when some fungible credit was already consumed" do
    issue("source", 100)
    open("consumed")
    open("active")

    apply_op("apply_hotel_credit", "use-consumed", %{
      "group_id" => "consumed",
      "amount_cents" => 60
    })

    apply_op("apply_hotel_credit", "use-active", %{"group_id" => "active", "amount_cents" => 50})

    apply_op("cancel_group", "consume", %{"group_id" => "consumed", "occurred_on" => "2027-05-03"})

    charge("charge", "pay-source")
    assert [%{unrecovered_clawback_cents: 110}] = Repo.all(CreditLot)

    assert %{credit_shortfall_cents: 50, credit_liability_cents: 50} =
             Reservations.ledger(~D[2027-01-01])

    apply_op("cancel_group", "restore", %{"group_id" => "active"})
    assert [%{unrecovered_clawback_cents: 60, remaining_cents: 0}] = Repo.all(CreditLot)

    assert %{credit_shortfall_cents: 0, credit_liability_cents: 0} =
             Reservations.ledger(~D[2027-01-01])
  end

  test "fully reduced and rejected payments cannot be charged or reconciled as applied cash" do
    open("g")
    assert %{code: "payment_exceeds_outstanding"} = pay("rejected", "g", 301)
    assert %{code: "payment_not_reducible"} = reduce("reduce-rejected", "rejected", 1)
    assert %{code: "payment_not_chargeable"} = charge("charge-rejected", "rejected")
    assert {:error, "payment_not_reconcilable"} = Payments.statement("rejected")
    assert %{code: "operation_not_found"} = charge("missing-charge", "missing")
    pay("p", "g", 100)
    reduce("reduce", "p", 100)
    assert %{code: "payment_not_chargeable"} = charge("charge", "p")
    assert %{reduced_cents: 100, charged_back_cents: 0} = statement("p")
  end

  test "new operation failures roll back every accounting write and can be retried" do
    issue("source", 100)
    open("g")
    pay("p", "g", 200)
    apply_op("apply_hotel_credit", "use", %{"group_id" => "g", "amount_cents" => 100})

    ops = [
      operation("reduce_cash_payment", "fault-reduce", %{
        "payment_operation_id" => "p",
        "amount_cents" => 20
      }),
      operation("cancel_rooms", "fault-cancel", %{
        "group_id" => "g",
        "room_ids" => ["r0", "r2"],
        "refund_method" => "hotel_credit"
      }),
      operation("charge_back_payment", "fault-charge", %{"payment_operation_id" => "p"})
    ]

    for op <- ops do
      before = snapshot()

      Repo.query!("""
      CREATE TRIGGER fail_correction_audit BEFORE INSERT ON partner_operations
      WHEN NEW.operation_id LIKE 'fault-%'
      BEGIN SELECT RAISE(ABORT, 'injected failure'); END
      """)

      assert_error_sent 500, fn ->
        build_conn() |> post("/api/v1/partner-batches", %{"operations" => [op]})
      end

      assert snapshot() == before
      assert Operations.get_result(op["operation_id"]) == nil
      Repo.query!("DROP TRIGGER fail_correction_audit")
      assert [%{status: "applied"}] = Reservations.submit([op])
    end
  end

  test "a batch observes corrections immediately and durably remembers room and reduction rejections" do
    open("g")
    pay("p", "g", 200)

    ops = [
      operation("reduce_cash_payment", "reduce", %{
        "payment_operation_id" => "p",
        "amount_cents" => 20,
        "expected_revision" => 2
      }),
      operation("cancel_rooms", "stale", %{
        "group_id" => "g",
        "room_ids" => ["r0"],
        "expected_revision" => 2
      }),
      operation("cancel_rooms", "cancel", %{
        "group_id" => "g",
        "room_ids" => ["r0"],
        "expected_revision" => 3
      }),
      operation("reduce_cash_payment", "too-much", %{
        "payment_operation_id" => "p",
        "amount_cents" => 81
      }),
      operation("charge_back_payment", "charge", %{
        "payment_operation_id" => "p",
        "expected_revision" => 4
      })
    ]

    response =
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)

    assert [reduce, stale, cancel, rejected, charge] = response["results"]
    assert reduce["revision"] == 3
    assert stale["actual_revision"] == 3
    assert cancel["cancelled_room_ids"] == ["r0"]
    assert rejected["code"] == "reduction_exceeds_held_cash"
    assert charge["revision"] == 5

    assert build_conn()
           |> post("/api/v1/partner-batches", %{"operations" => ops})
           |> json_response(200) == response
  end

  test "payment endpoint has exactly the reconciliation fields and does not mutate state" do
    open("g")
    pay("p", "g", 100)
    before = snapshot()
    response = build_conn() |> get("/api/v1/payments/p") |> json_response(200)

    assert response == %{
             "data" => %{
               "payment_operation_id" => "p",
               "original_group_id" => "g",
               "recorded_cents" => 100,
               "held_cents" => 100,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
           }

    assert build_conn() |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert build_conn() |> get("/api/v1/payments/open-g") |> json_response(422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }

    assert snapshot() == before
  end
end
