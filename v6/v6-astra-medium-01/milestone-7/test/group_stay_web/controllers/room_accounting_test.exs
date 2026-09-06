defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase
  import GroupStay.OperationFixture
  alias GroupStay.{Repo, Reservations}

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{operations: ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp read(path),
    do: build_conn() |> get("/api/v1" <> path) |> json_response(200) |> Map.fetch!("data")

  defp group(id \\ "group"), do: read("/groups/#{id}")
  defp ledger(on \\ "2027-05-02"), do: read("/ledger?on=#{on}")

  defp pay(id, n, group \\ "group"),
    do: operation(id, "record_cash_payment", %{"amount_cents" => n, "group_id" => group})

  defp cancel(id, rooms, attrs \\ %{}),
    do: operation(id, "cancel_rooms", Map.merge(%{"room_ids" => rooms}, attrs))

  defp reduce(id, payment, n, attrs \\ %{}),
    do:
      operation(
        id,
        "reduce_cash_payment",
        Map.merge(%{"payment_operation_id" => payment, "amount_cents" => n}, attrs)
      )
      |> Map.delete("group_id")

  defp charge(id, payment, attrs \\ %{}),
    do:
      operation(id, "charge_back_payment", Map.merge(%{"payment_operation_id" => payment}, attrs))
      |> Map.delete("group_id")

  defp statement(id) do
    result = read("/payments/#{id}")
    assert map_size(result) == 9

    assert result["recorded_cents"] ==
             Enum.sum(
               for key <-
                     ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                   do: result[key]
             )

    result
  end

  test "mixed funding fills rooms in processing order; reductions reopen the target's last fill" do
    batch([
      opening("source", "source"),
      pay("source-pay", 1000, "source"),
      operation("issue", "cancel_group", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      opening(),
      pay("p1", 3500),
      operation("credit", "apply_hotel_credit", %{"amount_cents" => 1000}),
      Map.put(pay("p2", 1000), "occurred_on", "2026-01-01")
    ])

    assert [a, b] = group()["rooms"]

    assert {a["deposit_due_cents"], a["lodging_total_cents"], a["cash_paid_cents"],
            a["credit_paid_cents"]} == {4000, 20000, 3500, 500}

    assert {b["cash_paid_cents"], b["credit_paid_cents"]} == {1000, 500}

    assert [%{"outstanding_deposit_cents" => 1100, "revision" => 5}] =
             batch([reduce("r1", "p2", 600)])

    assert [%{"outstanding_deposit_cents" => 1500}] = batch([reduce("r2", "p2", 400)])
    assert [%{"code" => "payment_not_reducible"}] = batch([reduce("r3", "p2", 1)])
    batch([pay("p3", 1500)])
    before = group()["rooms"] |> hd()

    assert [%{"cancelled_room_ids" => ["b"], "refunded_cents" => 1500}] =
             batch([cancel("cancel-b", ["b"])])

    assert hd(group()["rooms"]) == before
    assert group()["deposit_due_cents"] == 4000
    assert group()["deposit_paid_cents"] == 4000
    assert group()["lodging_total_cents"] == 20000
    assert ledger()["cash_reduced_cents"] == 1000
    assert statement("p2")["reduced_cents"] == 1000
    assert statement("p3")["refunded_cents"] == 1500
    assert [%{"refunded_cents" => 3500}] = batch([operation("rest", "cancel_group")])
    assert group()["status"] == "cancelled"

    for key <-
          ~w(lodging_total_cents deposit_due_cents deposit_paid_cents cash_paid_cents credit_paid_cents outstanding_deposit_cents),
        do: assert(group()[key] == 0)

    assert read("/guests/guest/credit?on=2027-05-02")["available_cents"] == 1100
  end

  test "reverse fill reductions preserve other payments and settle only held cash" do
    batch([opening(), pay("p", 5000), pay("other", 500)])
    batch([reduce("r", "p", 1500)])
    assert [a, b] = group()["rooms"]
    assert {a["cash_paid_cents"], b["cash_paid_cents"]} == {3500, 500}
    batch([cancel("a", ["a"], %{"refund_method" => "hotel_credit"})])
    assert [%{"code" => "payment_not_reducible"}] = batch([reduce("too-late", "p", 1)])
    assert statement("p")["converted_to_credit_cents"] == 3500
    assert statement("other")["held_cents"] == 500
  end

  test "selected room validation is atomic, canonicalizes order and combines bonus rounding" do
    small =
      Map.put(
        opening(),
        "rooms",
        for(id <- ~w(a b c), do: %{"room_id" => id, "nightly_rate_cents" => 5})
      )

    batch([small, pay("p", 6)])
    before = {group(), ledger()}

    for {ids, i} <- Enum.with_index([[], nil, "a", ["a", "a"], ["a", "missing"], [nil]]) do
      assert [%{"code" => "invalid_rooms"}] = batch([cancel("bad-#{i}", ids)])
      assert {group(), ledger()} == before
    end

    assert [%{"cancelled_room_ids" => ["a", "c"], "credit_issued_cents" => 4, "revision" => 3}] =
             batch([cancel("selected", ["c", "a"], %{"refund_method" => "hotel_credit"})])

    assert [%{"code" => "invalid_rooms"}] = batch([cancel("again", ["a", "b"])])
    assert [%{"cancelled_room_ids" => ["b"]}] = batch([cancel("last", ["b"])])
    assert group()["status"] == "cancelled"
  end

  test "payment targeting errors and revision precedence are durable" do
    batch([opening(), pay("p", 100), pay("rejected", 10000)])

    assert build_conn() |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    for id <- ["open", "rejected"] do
      assert build_conn() |> get("/api/v1/payments/#{id}") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }

      assert [%{"code" => "payment_not_reducible"}] = batch([reduce("reduce-#{id}", id, 1)])
      assert [%{"code" => "payment_not_chargeable"}] = batch([charge("charge-#{id}", id)])
    end

    for {value, i} <- Enum.with_index([0, -1, 1.0, "1", nil, true]) do
      assert [%{"code" => "invalid_amount"}] = batch([reduce("invalid-#{i}", "p", value)])
    end

    assert [%{"code" => "operation_not_found"}] = batch([charge("missing", "missing")])
    assert [%{"code" => "reduction_exceeds_held_cash"}] = batch([reduce("too-much", "p", 101)])
    stale = reduce("stale", "p", -1, %{"expected_revision" => 1})
    assert [result = %{"code" => "stale_revision", "actual_revision" => 2}] = batch([stale])
    batch([cancel("cancelled", ["a", "b"])])
    assert [^result] = batch([stale])

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(stale, "expected_revision", 3)])

    for op <- [
          reduce("stale-empty", "p", 1, %{"expected_revision" => 1}),
          charge("stale-charge", "p", %{"expected_revision" => 1})
        ] do
      assert [%{"code" => "stale_revision", "actual_revision" => 3}] = batch([op])
    end

    assert [%{"charged_back_cents" => 100, "revision" => 4}] =
             batch([charge("charge", "p", %{"expected_revision" => 3})])

    assert [%{"code" => "payment_not_chargeable"}] = batch([charge("charge-again", "p")])
    assert statement("p")["charged_back_cents"] == 100
  end

  test "chargeback reclassifies all dispositions, leaves reduced cash and preserves original results" do
    rooms = for id <- ~w(a b c d e), do: %{"room_id" => id, "nightly_rate_cents" => 250}
    [_, original] = batch([Map.put(opening(), "rooms", rooms), pay("p", 500)])

    batch([
      cancel("refund", ["a"]),
      cancel("retain", ["b"], %{"occurred_on" => "2027-05-03"}),
      cancel("convert", ["c"], %{"refund_method" => "hotel_credit"}),
      reduce("reduce", "p", 50)
    ])

    assert statement("p") == %{
             "payment_operation_id" => "p",
             "original_group_id" => "group",
             "recorded_cents" => 500,
             "held_cents" => 150,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 100,
             "reduced_cents" => 50,
             "charged_back_cents" => 0
           }

    op = charge("cb", "p")

    assert [
             result = %{
               "charged_back_cents" => 450,
               "outstanding_deposit_cents" => 200,
               "revision" => 7
             }
           ] = batch([op])

    assert [^result] = batch([op])
    assert [^original] = batch([pay("p", 500)])
    assert read("/operations/p") == original
    assert statement("p")["charged_back_cents"] == 450

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 50,
             "cash_charged_back_cents" => 450,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  test "entitlements telescope by payment commit order, with fungible spending and restoration absorption" do
    batch([
      opening(),
      pay("first", 4),
      Map.put(pay("second", 1), "occurred_on", "2026-01-01"),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("target", "target"),
      operation("use", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 5})
    ])

    target = group("target")
    batch([charge("second-cb", "second")])
    assert ledger()["credit_shortfall_cents"] == 1
    assert ledger()["credit_liability_cents"] == 5
    assert group("target") == target
    batch([charge("first-cb", "first")])
    assert ledger()["credit_shortfall_cents"] == 5
    assert ledger()["credit_liability_cents"] == 5
    batch([operation("return", "cancel_group", %{"group_id" => "target"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert read("/guests/guest/credit?on=2027-05-02")["lots"] == []
  end

  test "shortfall tracks active credit, absorbs before expiry and never changes recipient revisions" do
    for {suffix, cancel_on} <- [{"refundable", "2028-05-03"}, {"nonrefundable", "2028-07-01"}] do
      src = "source-#{suffix}"
      target = "target-#{suffix}"

      target_open =
        opening("open-#{target}", target)
        |> Map.merge(%{"arrival_on" => "2028-07-01", "departure_on" => "2028-07-02"})

      batch([
        opening("open-#{src}", src),
        pay("p-#{suffix}", 100, src),
        operation("issue-#{suffix}", "cancel_group", %{
          "group_id" => src,
          "refund_method" => "hotel_credit"
        }),
        target_open,
        operation("use-#{suffix}", "apply_hotel_credit", %{
          "group_id" => target,
          "amount_cents" => 110
        })
      ])

      before = group(target)
      batch([charge("cb-#{suffix}", "p-#{suffix}")])
      assert group(target) == before
      assert ledger("2028-05-03")["credit_shortfall_cents"] == 110
      assert ledger("2028-05-03")["credit_liability_cents"] == 110

      batch([
        operation("return-#{suffix}", "cancel_group", %{
          "group_id" => target,
          "occurred_on" => cancel_on
        })
      ])

      assert ledger("2028-05-03")["credit_shortfall_cents"] == 0
      assert ledger("2028-05-03")["credit_liability_cents"] == 0
    end
  end

  test "partial clawbacks absorb returns before making excess available and keep lot spending fungible" do
    batch([
      opening(),
      pay("p1", 100),
      pay("p2", 100),
      pay("p3", 100),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("t1", "t1"),
      opening("t2", "t2"),
      operation("use1", "apply_hotel_credit", %{"group_id" => "t1", "amount_cents" => 150}),
      operation("use2", "apply_hotel_credit", %{"group_id" => "t2", "amount_cents" => 100}),
      charge("cb1", "p1")
    ])

    assert ledger()["credit_shortfall_cents"] == 30
    assert ledger()["credit_liability_cents"] == 250
    batch([operation("return1", "cancel_group", %{"group_id" => "t1"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 220
    assert read("/guests/guest/credit?on=2027-05-02")["available_cents"] == 120
    batch([charge("cb2", "p2")])
    assert ledger()["credit_liability_cents"] == 110
    batch([charge("cb3", "p3")])
    assert ledger()["credit_shortfall_cents"] == 100

    batch([
      operation("consume", "cancel_group", %{"group_id" => "t2", "occurred_on" => "2027-05-03"})
    ])

    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
  end

  test "shortfall is capped by active credit after other entitlement has already been consumed" do
    batch([
      opening(),
      pay("p1", 100),
      pay("p2", 100),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("t1", "t1"),
      opening("t2", "t2"),
      operation("use1", "apply_hotel_credit", %{"group_id" => "t1", "amount_cents" => 200}),
      operation("use2", "apply_hotel_credit", %{"group_id" => "t2", "amount_cents" => 20}),
      operation("consume", "cancel_group", %{"group_id" => "t1", "occurred_on" => "2027-05-03"}),
      charge("cb", "p1")
    ])

    assert ledger()["credit_shortfall_cents"] == 20
    assert ledger()["credit_liability_cents"] == 20
    batch([operation("return", "cancel_group", %{"group_id" => "t2"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
  end

  test "chargeback credit revocation is rolled back if its audit record cannot commit" do
    batch([
      opening(),
      pay("p", 100),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("target", "target"),
      operation("use", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 50})
    ])

    before = {group(), group("target"), ledger(), statement("p"), Repo.all(GroupStay.CreditLot)}

    Repo.query!(
      "CREATE TRIGGER fail_operation BEFORE INSERT ON operations WHEN NEW.operation_id = 'fail' BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END"
    )

    assert_error_sent 500, fn -> batch([charge("fail", "p")]) end

    assert {group(), group("target"), ledger(), statement("p"), Repo.all(GroupStay.CreditLot)} ==
             before

    assert Reservations.get_operation("fail") == nil
    Repo.query!("DROP TRIGGER fail_operation")
    batch([charge("fail", "p")])
    assert ledger()["credit_shortfall_cents"] == 50
  end

  test "one payment's entitlement is independent for each issued lot" do
    batch([
      opening(),
      pay("p", 6000),
      cancel("lot-a", ["a"], %{"refund_method" => "hotel_credit"}),
      cancel("lot-b", ["b"], %{"refund_method" => "hotel_credit"})
    ])

    assert ledger()["credit_liability_cents"] == 6600
    batch([charge("cb", "p")])
    assert ledger()["credit_liability_cents"] == 0
    assert statement("p")["charged_back_cents"] == 6000
  end

  test "new operation audit failures roll back every allocation and entitlement mutation" do
    batch([opening(), pay("p", 5000)])

    for op <- [
          reduce("fail", "p", 100),
          cancel("fail", ["a"], %{"refund_method" => "hotel_credit"}),
          charge("fail", "p")
        ] do
      before =
        {group(), ledger(), statement("p"), Repo.all(GroupStay.CashAllocation),
         Repo.all(GroupStay.CreditLot)}

      Repo.query!(
        "CREATE TRIGGER fail_operation BEFORE INSERT ON operations WHEN NEW.operation_id = 'fail' BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END"
      )

      assert_error_sent 500, fn -> batch([op]) end

      assert {group(), ledger(), statement("p"), Repo.all(GroupStay.CashAllocation),
              Repo.all(GroupStay.CreditLot)} == before

      assert Reservations.get_operation("fail") == nil
      Repo.query!("DROP TRIGGER fail_operation")
    end
  end
end
