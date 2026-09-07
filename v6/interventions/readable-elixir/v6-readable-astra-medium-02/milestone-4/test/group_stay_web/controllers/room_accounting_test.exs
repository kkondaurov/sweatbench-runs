defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false
  alias GroupStay.{Repo, Operations.Record}

  alias GroupStay.Reservations.{
    Group,
    CashAllocation,
    CreditAllocation,
    CreditLot,
    CreditEntitlement
  }

  defp batch(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp op(type, id, fields \\ %{}) do
    Map.merge(
      %{"type" => type, "operation_id" => id, "occurred_on" => "2027-01-01", "group_id" => "g"},
      fields
    )
  end

  defp opening(group \\ "g", fields \\ %{}) do
    op(
      "open_group",
      "open-" <> group,
      Map.merge(
        %{
          "group_id" => group,
          "guest_id" => "guest",
          "property_id" => "hotel",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02",
          "rate_plan" => "flexible",
          "rooms" => for(id <- ~w(a b c), do: %{"room_id" => id, "nightly_rate_cents" => 500})
        },
        fields
      )
    )
  end

  defp pay(id, amount, group \\ "g"),
    do: op("record_cash_payment", id, %{"amount_cents" => amount, "group_id" => group})

  defp reduce(id, target, amount, fields \\ %{}),
    do:
      op(
        "reduce_cash_payment",
        id,
        Map.merge(%{"payment_operation_id" => target, "amount_cents" => amount}, fields)
      )
      |> Map.delete("group_id")

  defp charge(id, target, fields \\ %{}),
    do:
      op("charge_back_payment", id, Map.put(fields, "payment_operation_id", target))
      |> Map.delete("group_id")

  defp cancel(id, rooms, fields \\ %{}),
    do: op("cancel_rooms", id, Map.put(fields, "room_ids", rooms))

  defp get(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp group(id \\ "g"), do: get("groups/" <> id)
  defp ledger(on \\ "2027-01-01"), do: get("ledger?on=" <> on)

  defp statement(id, expected) do
    data = get("payments/" <> id)

    assert Map.keys(data) |> Enum.sort() ==
             ~w(payment_operation_id original_group_id recorded_cents held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
             |> Enum.sort()

    assert Enum.sum(
             for field <-
                   ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                 do: data[field]
           ) == data["recorded_cents"]

    for {field, value} <- expected, do: assert(data[field] == value)
    data
  end

  defp snapshot do
    for schema <- [Group, CashAllocation, CreditAllocation, CreditLot, CreditEntitlement],
        do: Repo.all(schema)
  end

  defp seed_credit(amount \\ 100) do
    batch([
      opening("source"),
      pay("source-pay", amount, "source"),
      op("cancel_group", "source-cancel", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      })
    ])
  end

  test "mixed funding fills rooms in processing order and selected settlement leaves other rooms intact" do
    seed_credit()
    original_payment = pay("p1", 150)

    results =
      batch([
        opening(),
        original_payment,
        op("apply_hotel_credit", "credit", %{"amount_cents" => 80}),
        pay("p2", 70)
      ])

    rooms = group()["rooms"]

    assert Enum.map(rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {100, 0},
             {50, 50},
             {70, 30}
           ]

    cancellation =
      cancel("partial", ["c", "a"], %{"refund_method" => "hotel_credit", "expected_revision" => 4})

    assert [
             %{
               "cancelled_room_ids" => ["a", "c"],
               "credit_issued_cents" => 187,
               "refunded_cents" => 0,
               "revision" => 5
             } = result
           ] = batch([cancellation])

    assert Enum.at(group()["rooms"], 1) == Enum.at(rooms, 1)

    assert %{
             "lodging_total_cents" => 500,
             "deposit_due_cents" => 100,
             "cash_paid_cents" => 50,
             "credit_paid_cents" => 50
           } = group()

    assert [^result] = batch([cancellation])
    assert [original] = batch([original_payment])
    assert original == Enum.at(results, 1)
    statement("p1", %{"held_cents" => 50, "converted_to_credit_cents" => 100})
    statement("p2", %{"converted_to_credit_cents" => 70})
    assert [%{"refunded_cents" => 50, "revision" => 6}] = batch([op("cancel_group", "rest")])

    assert %{"status" => "cancelled", "lodging_total_cents" => 0, "deposit_paid_cents" => 0} =
             group()

    assert Enum.all?(group()["rooms"], &(&1["status"] == "cancelled"))
    assert ledger()["credit_liability_cents"] == 297
  end

  test "reductions follow the target payment in reverse fill order and compose with new funding" do
    payment = pay("p", 250)
    [_, original] = batch([opening(), payment])
    reduction = reduce("r1", "p", 80, %{"expected_revision" => 2})
    assert [%{"outstanding_deposit_cents" => 130, "revision" => 3} = result] = batch([reduction])
    assert Enum.map(group()["rooms"], & &1["cash_paid_cents"]) == [100, 70, 0]
    batch([pay("other", 100), cancel("cancel-b", ["b"])])

    assert [%{"code" => "reduction_exceeds_held_cash"}, %{"amount_cents" => 100}] =
             batch([reduce("too-much", "p", 101), reduce("rest", "p", 100)])

    assert Enum.map(group()["rooms"], & &1["cash_paid_cents"]) == [0, 0, 70]

    statement("p", %{
      "recorded_cents" => 250,
      "refunded_cents" => 70,
      "reduced_cents" => 180,
      "held_cents" => 0
    })

    statement("other", %{"held_cents" => 70, "refunded_cents" => 30})
    assert [^result, ^original] = batch([reduction, payment])
    assert ledger()["cash_reduced_cents"] == 180
    assert [%{"code" => "payment_not_reducible"}] = batch([reduce("empty", "p", 1)])
  end

  test "room and payment validation preserves domain state and stale revisions win" do
    batch([opening(), pay("p", 100)])
    before = snapshot()

    for {rooms, index} <- Enum.with_index([[], ["a", "a"], ["missing"], [nil], "a"]) do
      assert [%{"code" => "invalid_rooms"}] = batch([cancel("invalid-#{index}", rooms)])
      assert snapshot() == before
    end

    for {amount, index} <- Enum.with_index([0, -1, 1.1, "1", nil]) do
      assert [%{"code" => "invalid_amount"}] = batch([reduce("amount-#{index}", "p", amount)])
      assert snapshot() == before
    end

    stale = reduce("stale", "p", -1, %{"expected_revision" => 1})
    assert [%{"code" => "stale_revision", "actual_revision" => 2} = rejection] = batch([stale])

    assert [%{"code" => "stale_revision"}] =
             batch([cancel("stale-rooms", [], %{"expected_revision" => 1})])

    assert [%{"code" => "operation_not_found"}] = batch([reduce("missing", "legacy", 1)])
    assert [%{"code" => "payment_not_reducible"}] = batch([reduce("not-payment", "open-g", 1)])
    batch([cancel("done", ["a", "b", "c"])])
    assert [^rejection] = batch([stale])

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(stale, "expected_revision", 3)])

    assert [%{"code" => "stale_revision"}] =
             batch([reduce("stale-cancelled", "p", 1, %{"expected_revision" => 2})])

    assert [%{"code" => "payment_not_reducible"}] = batch([reduce("settled", "p", 1)])
  end

  test "chargeback reclassifies every cash disposition except reductions and preserves original results" do
    rooms = for id <- ~w(a b c d e), do: %{"room_id" => id, "nightly_rate_cents" => 500}
    payment = pay("p", 500)
    [_, original] = batch([opening("g", %{"rooms" => rooms}), payment])

    batch([
      reduce("reduced", "p", 40),
      cancel("refund", ["a"]),
      cancel("convert", ["b"], %{"refund_method" => "hotel_credit"}),
      cancel("retain", ["c"], %{"occurred_on" => "2027-05-31"})
    ])

    statement("p", %{
      "held_cents" => 160,
      "refunded_cents" => 100,
      "retained_cents" => 100,
      "converted_to_credit_cents" => 100,
      "reduced_cents" => 40
    })

    chargeback = charge("cb", "p", %{"expected_revision" => 6})

    assert [
             %{"charged_back_cents" => 460, "outstanding_deposit_cents" => 200, "revision" => 7} =
               result
           ] = batch([chargeback])

    statement("p", %{
      "held_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 40,
      "charged_back_cents" => 460
    })

    assert %{
             "cash_charged_back_cents" => 460,
             "cash_reduced_cents" => 40,
             "credit_liability_cents" => 0
           } = ledger()

    assert [^result, ^original] = batch([chargeback, payment])
    assert [%{"code" => "payment_not_chargeable"}] = batch([charge("again", "p")])
  end

  test "entitlements telescope across payments and shortfall follows fungible applied credit" do
    batch([
      opening(),
      pay("p1", 5),
      pay("p2", 5),
      op("cancel_group", "issue", %{"refund_method" => "hotel_credit"}),
      opening("destination"),
      op("apply_hotel_credit", "spend", %{"group_id" => "destination", "amount_cents" => 8})
    ])

    destination = group("destination")
    assert [%{"charged_back_cents" => 5, "revision" => 5}] = batch([charge("cb1", "p1")])
    assert group("destination") == destination
    assert %{"credit_liability_cents" => 8, "credit_shortfall_cents" => 3} = ledger()
    assert [%{"charged_back_cents" => 5}] = batch([charge("cb2", "p2")])
    assert ledger()["credit_shortfall_cents"] == 8
    assert get("guests/guest/credit?on=2027-01-01")["available_cents"] == 0
    batch([op("cancel_group", "restore", %{"group_id" => "destination"})])
    assert %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0} = ledger()
    assert Repo.one(CreditLot).unrecovered_clawback_cents == 0
  end

  test "restoration absorbs clawback before expiry and nonrefundable consumption shrinks shortfall" do
    seed_credit()

    batch([
      opening(),
      op("apply_hotel_credit", "spend", %{"amount_cents" => 110}),
      charge("cb", "source-pay")
    ])

    assert ledger()["credit_shortfall_cents"] == 110
    batch([cancel("consume", ["a"], %{"occurred_on" => "2027-05-31"})])
    assert %{"credit_shortfall_cents" => 10, "credit_liability_cents" => 10} = ledger()

    batch([
      op("reschedule_group", "move", %{"new_arrival_on" => "2029-06-01"}),
      cancel("restore-expired", ["b"], %{"occurred_on" => "2028-01-02"})
    ])

    assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0} = ledger("2028-01-02")
    assert Repo.one(CreditLot).unrecovered_clawback_cents == 100
    assert Repo.one(CreditLot).remaining_cents == 0
  end

  test "partial clawback restores excess without a second bonus" do
    batch([
      opening(),
      pay("p1", 50),
      pay("p2", 50),
      op("cancel_group", "issue", %{"refund_method" => "hotel_credit"}),
      opening("destination"),
      op("apply_hotel_credit", "spend", %{"group_id" => "destination", "amount_cents" => 100}),
      charge("cb", "p1")
    ])

    assert %{"credit_shortfall_cents" => 45, "credit_liability_cents" => 100} = ledger()

    batch([
      op("cancel_group", "restore", %{
        "group_id" => "destination",
        "refund_method" => "hotel_credit"
      })
    ])

    assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 55} = ledger()
    assert get("guests/guest/credit?on=2027-01-01")["available_cents"] == 55
  end

  test "selected rooms share one rounded bonus and keep the inclusive policy boundary" do
    rooms =
      for {id, rate} <- [{"a", 5}, {"b", 20}, {"c", 500}],
          do: %{"room_id" => id, "nightly_rate_cents" => rate}

    batch([opening("g", %{"rooms" => rooms}), pay("p", 5)])

    assert [%{"credit_issued_cents" => 6, "cancelled_room_ids" => ["a", "b"]}] =
             batch([
               cancel("boundary", ["b", "a"], %{
                 "occurred_on" => "2027-05-02",
                 "refund_method" => "hotel_credit"
               })
             ])

    before = snapshot()

    assert [
             %{"code" => "invalid_rooms"},
             %{"code" => "refund_method_not_available"},
             %{"code" => "invalid_refund_method"}
           ] =
             batch([
               cancel("already", ["a", "c"]),
               cancel("late", ["c"], %{
                 "occurred_on" => "2027-05-03",
                 "refund_method" => "hotel_credit"
               }),
               cancel("bad-method", ["c"], %{"refund_method" => "voucher"})
             ])

    assert snapshot() == before
    assert [%{"refunded_cents" => 0, "retained_cents" => 0}] = batch([cancel("unpaid", ["c"])])
    assert group()["status"] == "cancelled"
  end

  test "one payment's entitlements are rounded independently for each conversion lot" do
    rooms = for id <- ~w(a b c), do: %{"room_id" => id, "nightly_rate_cents" => 25}
    batch([opening("g", %{"rooms" => rooms}), pay("first", 3), pay("second", 7)])

    assert [%{"credit_issued_cents" => 6}, %{"credit_issued_cents" => 6}] =
             batch([
               cancel("lot1", ["a"], %{"refund_method" => "hotel_credit"}),
               cancel("lot2", ["b"], %{"refund_method" => "hotel_credit"})
             ])

    assert [%{"charged_back_cents" => 7}] = batch([charge("cb", "second")])
    statement("second", %{"charged_back_cents" => 7, "converted_to_credit_cents" => 0})
    assert ledger()["credit_liability_cents"] == 3

    assert [%{"remaining_cents" => 3, "source_operation_id" => "lot1"}] =
             get("guests/guest/credit?on=2027-01-01")["lots"]
  end

  test "spent and expired entitlement can be unrecovered without a current shortfall" do
    seed_credit()

    batch([
      opening(),
      op("apply_hotel_credit", "spend", %{"amount_cents" => 100}),
      op("cancel_group", "consume", %{"occurred_on" => "2027-05-31"}),
      charge("cb", "source-pay", %{"occurred_on" => "2028-01-02"})
    ])

    assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0} = ledger("2028-01-02")
    assert Repo.one(CreditLot).unrecovered_clawback_cents == 100
    assert Repo.one(CreditLot).remaining_cents == 0
  end

  test "payment reads and unchargeable targets use the specified status and errors" do
    batch([opening(), pay("bad", 301), pay("p", 10), reduce("all", "p", 10)])

    assert build_conn() |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    for id <- ["open-g", "bad"] do
      assert build_conn() |> get("/api/v1/payments/" <> id) |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }

      assert [%{"code" => "payment_not_chargeable"}] = batch([charge("cb-" <> id, id)])
    end

    before = snapshot()
    statement("p", %{"recorded_cents" => 10, "reduced_cents" => 10})
    assert snapshot() == before
    assert [%{"code" => "payment_not_chargeable"}] = batch([charge("fully-reduced", "p")])
    assert [%{"code" => "operation_not_found"}] = batch([charge("missing-cb", "missing")])
    assert Repo.get_by!(Record, operation_id: "p").result["revision"] == 2
  end
end
