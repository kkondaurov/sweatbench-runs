defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Repo, Reservations}

  defp open(id \\ "g", rates \\ [1000, 1000, 1000], extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{id}",
        "type" => "open_group",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "flexible",
        "rooms" =>
          Enum.with_index(rates, fn rate, i ->
            %{"room_id" => "r#{i}", "nightly_rate_cents" => rate}
          end)
      },
      extra
    )
  end

  defp op(id, type, extra \\ %{}) do
    Map.merge(
      %{"operation_id" => id, "type" => type, "group_id" => "g", "occurred_on" => "2027-02-01"},
      extra
    )
  end

  defp pay(id, amount, group \\ "g"),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount})

  defp cancel(id, rooms, extra \\ %{}),
    do: op(id, "cancel_rooms", Map.put(extra, "room_ids", rooms))

  defp reduce(id, payment, amount, extra \\ %{}),
    do:
      op(
        id,
        "reduce_cash_payment",
        Map.merge(%{"payment_operation_id" => payment, "amount_cents" => amount}, extra)
      )
      |> Map.delete("group_id")

  defp charge(id, payment, extra \\ %{}),
    do:
      op(id, "charge_back_payment", Map.put(extra, "payment_operation_id", payment))
      |> Map.delete("group_id")

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp apply!(op) do
    [result] = batch([op])
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp group(id \\ "g"),
    do: build_conn() |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger(on \\ "2027-02-01"),
    do:
      build_conn()
      |> get("/api/v1/ledger", %{"on" => on})
      |> json_response(200)
      |> Map.fetch!("data")

  defp credit(on \\ "2027-02-01"),
    do: Reservations.guest_credit("guest", Date.from_iso8601!(on)).available_cents

  defp statement(id) do
    data =
      build_conn() |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

    assert Map.keys(data) |> Enum.sort() ==
             Enum.sort(
               ~w(payment_operation_id original_group_id recorded_cents held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
             )

    assert Enum.sum(
             for key <-
                   ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                 do: data[key]
           ) == data["recorded_cents"]

    data
  end

  defp balances do
    {group(), ledger(), credit(), Repo.all(GroupStay.Reservations.Funding),
     Repo.all(GroupStay.Reservations.CreditLot)}
  end

  test "room pricing, ordered mixed funding, partial settlement and final cancellation" do
    apply!(open("source"))
    apply!(pay("source-cash", 200, "source"))

    apply!(
      op("issue", "cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"})
    )

    apply!(open())
    apply!(pay("first", 150))
    apply!(op("credit", "apply_hotel_credit", %{"amount_cents" => 220}))
    apply!(pay("last", 180))

    assert Enum.map(group()["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {150, 50},
             {30, 170},
             {150, 0}
           ]

    assert Enum.map(group()["rooms"], &{&1["lodging_total_cents"], &1["deposit_due_cents"]}) == [
             {1000, 200},
             {1000, 200},
             {1000, 200}
           ]

    result =
      apply!(
        cancel("partial", ["r2", "r0"], %{
          "refund_method" => "hotel_credit",
          "expected_revision" => 4
        })
      )

    assert result["cancelled_room_ids"] == ["r0", "r2"]
    assert result["credit_issued_cents"] == 330
    assert result["revision"] == 5
    assert credit() == 380
    g = group()

    assert {g["status"], g["lodging_total_cents"], g["deposit_due_cents"],
            g["deposit_paid_cents"], g["outstanding_deposit_cents"]} ==
             {"active", 1000, 200, 200, 0}

    assert Enum.map(g["rooms"], & &1["status"]) == ["cancelled", "active", "cancelled"]
    assert Enum.at(g["rooms"], 1)["credit_paid_cents"] == 170
    assert statement("last")["converted_to_credit_cents"] == 150
    final = apply!(op("final", "cancel_group"))
    assert final["refunded_cents"] == 30
    assert final["revision"] == 6
    assert group()["lodging_total_cents"] == 0
    assert group()["status"] == "cancelled"
    assert credit() == 550
    assert ledger()["cash_converted_to_credit_cents"] == 500
    assert ledger()["cash_refunded_cents"] == 30

    assert batch([
             cancel("partial", ["r2", "r0"], %{
               "refund_method" => "hotel_credit",
               "expected_revision" => 4
             })
           ]) == [result]
  end

  test "reductions target held cash in reverse fill order and replay original payments" do
    apply!(open())
    payment = pay("p", 500)
    original = apply!(payment)
    apply!(pay("q", 100))
    result = apply!(reduce("reduce", "p", 150, %{"expected_revision" => 3}))
    assert result["outstanding_deposit_cents"] == 150
    assert Enum.map(group()["rooms"], & &1["cash_paid_cents"]) == [200, 150, 100]
    apply!(cancel("refund", ["r0"]))
    assert statement("p")["refunded_cents"] == 200
    assert statement("p")["reduced_cents"] == 150
    assert statement("p")["held_cents"] == 150
    apply!(reduce("reduce-all", "p", 150))
    assert statement("p")["held_cents"] == 0
    assert ledger()["cash_reduced_cents"] == 300
    assert group()["outstanding_deposit_cents"] == 300
    before = balances()

    assert batch([payment, reduce("reduce", "p", 150, %{"expected_revision" => 3})]) == [
             original,
             result
           ]

    assert balances() == before
    assert [%{"code" => "payment_not_reducible"}] = batch([reduce("empty", "p", 1)])
    assert [%{"code" => "operation_id_conflict"}] = batch([reduce("reduce", "p", 149)])
    apply!(pay("refill", 250))
    assert Enum.map(group()["rooms"], & &1["cash_paid_cents"]) == [0, 200, 150]
  end

  test "invalid selections and amounts leave all accounting unchanged; revision is checked first" do
    apply!(open())
    apply!(pay("p", 100))
    before = balances()

    for {operation, code} <- [
          {cancel("empty", []), "invalid_rooms"},
          {cancel("duplicate", ["r0", "r0"]), "invalid_rooms"},
          {cancel("unknown", ["r0", "no"]), "invalid_rooms"},
          {cancel("not-list", "r0"), "invalid_rooms"},
          {cancel("method", ["r0"], %{"refund_method" => "other"}), "invalid_operation"},
          {cancel("late-credit", ["r0"], %{
             "refund_method" => "hotel_credit",
             "occurred_on" => "2027-05-03"
           }), "refund_method_not_available"},
          {reduce("zero", "p", 0), "invalid_amount"},
          {reduce("negative", "p", -1), "invalid_amount"},
          {reduce("float", "p", 1.0), "invalid_amount"},
          {reduce("large", "p", 101), "reduction_exceeds_held_cash"},
          {reduce("missing", "absent", 1), "operation_not_found"},
          {reduce("wrong", "open-g", 1), "payment_not_reducible"},
          {charge("wrong-charge", "open-g"), "payment_not_chargeable"},
          {charge("missing-charge", "absent"), "operation_not_found"},
          {cancel("stale-room", [], %{"expected_revision" => 1}), "stale_revision"},
          {reduce("stale-reduction", "p", 0, %{"expected_revision" => 1}), "stale_revision"},
          {charge("stale-charge", "p", %{"expected_revision" => 1}), "stale_revision"}
        ] do
      assert [%{"code" => ^code}] = batch([operation])
      assert balances() == before
    end

    apply!(cancel("cancelled", ["r0"]))
    assert [%{"code" => "invalid_rooms"}] = batch([cancel("again", ["r0", "r1"])])

    assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
             batch([reduce("stale-empty", "p", 1, %{"expected_revision" => 2})])

    apply!(op("close", "cancel_group"))
    assert [%{"code" => "group_not_active"}] = batch([cancel("inactive", ["r1"])])
  end

  test "chargeback reclassifies held, refunded, retained, converted and excludes reduced cash" do
    apply!(open("g", [1000, 1000, 1000, 1000]))
    original = apply!(pay("p", 800))
    apply!(cancel("refund", ["r0"]))
    apply!(cancel("convert", ["r1"], %{"refund_method" => "hotel_credit"}))
    apply!(cancel("retain", ["r2"], %{"occurred_on" => "2027-05-10"}))
    apply!(reduce("reduce", "p", 50))
    before = statement("p")

    assert {before["held_cents"], before["refunded_cents"], before["retained_cents"],
            before["converted_to_credit_cents"], before["reduced_cents"]} ==
             {150, 200, 200, 200, 50}

    result = apply!(charge("charge", "p", %{"expected_revision" => 6}))
    assert result["charged_back_cents"] == 750
    assert result["outstanding_deposit_cents"] == 200
    assert result["revision"] == 7
    assert statement("p")["charged_back_cents"] == 750

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 50,
             "cash_charged_back_cents" => 750,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    snapshot = balances()

    assert batch([pay("p", 800), charge("charge", "p", %{"expected_revision" => 6})]) == [
             original,
             result
           ]

    assert balances() == snapshot
    assert [%{"code" => "payment_not_chargeable"}] = batch([charge("again", "p")])
    assert [%{"code" => "payment_not_reducible"}] = batch([reduce("again-reduce", "p", 1)])
  end

  test "entitlements telescope per lot and spent credit is fungible with shortfall absorption" do
    apply!(open("g", [25, 25]))
    apply!(pay("p", 5))
    apply!(pay("q", 5))
    apply!(op("convert", "cancel_group", %{"refund_method" => "hotel_credit"}))
    assert credit() == 11
    apply!(open("target", [25, 25]))
    apply!(op("redeem", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 10}))
    target = group("target")
    assert apply!(charge("charge-q", "q"))["charged_back_cents"] == 5
    # q owns 11 - 6 = 5; remove 1 available and leave a shortfall of 4.
    assert credit() == 0
    assert ledger()["credit_shortfall_cents"] == 4
    assert ledger()["credit_liability_cents"] == 10
    assert group("target") == target
    apply!(cancel("return", ["r0"], %{"group_id" => "target"}))
    assert credit() == 1
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 6
    apply!(charge("charge-p", "p"))
    assert credit() == 0
    assert ledger()["credit_shortfall_cents"] == 5

    apply!(
      op("consume", "cancel_group", %{"group_id" => "target", "occurred_on" => "2027-05-10"})
    )

    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert statement("p")["charged_back_cents"] == 5
    assert statement("q")["charged_back_cents"] == 5
  end

  test "restoration absorbs clawback before expiry, and each conversion lot has its own bonus" do
    apply!(open("g", [25, 25]))
    apply!(pay("p", 10))

    assert apply!(cancel("first-lot", ["r0"], %{"refund_method" => "hotel_credit"}))[
             "credit_issued_cents"
           ] == 6

    assert apply!(cancel("second-lot", ["r1"], %{"refund_method" => "hotel_credit"}))[
             "credit_issued_cents"
           ] == 6

    apply!(open("target", [50], %{"arrival_on" => "2029-06-01", "departure_on" => "2029-06-02"}))
    apply!(op("spend", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 10}))
    apply!(charge("charge", "p"))
    assert ledger()["credit_shortfall_cents"] == 10
    assert ledger("2028-02-02")["credit_liability_cents"] == 10

    apply!(
      op("expired-return", "cancel_group", %{
        "group_id" => "target",
        "occurred_on" => "2028-02-02"
      })
    )

    assert credit("2028-02-02") == 0
    assert ledger("2028-02-02")["credit_shortfall_cents"] == 0
    assert ledger("2028-02-02")["credit_liability_cents"] == 0

    assert Enum.all?(
             Repo.all(GroupStay.Reservations.CreditLot),
             &(&1.unrecovered_clawback_cents == 0)
           )
  end

  test "payment endpoint rejects missing, noncash and rejected records without changing state" do
    apply!(open())
    assert [%{"code" => "invalid_amount"}] = batch([pay("rejected", 0)])

    for {id, status, code} <- [
          {"missing", 404, "operation_not_found"},
          {"open-g", 422, "payment_not_reconcilable"},
          {"rejected", 422, "payment_not_reconcilable"}
        ] do
      assert build_conn() |> get("/api/v1/payments/#{id}") |> json_response(status) == %{
               "error" => %{"code" => code}
             }
    end

    apply!(pay("p", 100))
    apply!(reduce("all", "p", 100))
    assert [%{"code" => "payment_not_chargeable"}] = batch([charge("fully-reduced", "p")])
    before = balances()
    assert statement("p")["reduced_cents"] == 100
    assert balances() == before
  end

  test "same-batch partial cancellation combines rounding and later corrections observe its revision" do
    operations = [
      open("g", [25, 25, 25]),
      pay("p", 5),
      pay("q", 10),
      cancel("convert", ["r1", "r0"], %{
        "refund_method" => "hotel_credit",
        "expected_revision" => 3
      }),
      reduce("too-large", "q", 6, %{"expected_revision" => 4}),
      reduce("reduce", "q", 2, %{"expected_revision" => 4}),
      charge("charge", "q", %{"expected_revision" => 5})
    ]

    results = batch(operations)
    assert Enum.at(results, 3)["credit_issued_cents"] == 11
    assert Enum.at(results, 3)["cancelled_room_ids"] == ["r0", "r1"]
    assert Enum.at(results, 4)["code"] == "reduction_exceeds_held_cash"
    assert Enum.at(results, 6)["charged_back_cents"] == 8
    assert Enum.at(results, 6)["revision"] == 6
    assert credit() == 6
    assert statement("q")["reduced_cents"] == 2
    assert statement("q")["charged_back_cents"] == 8
    assert group()["outstanding_deposit_cents"] == 5
    snapshot = balances()
    assert batch(operations) == results
    assert balances() == snapshot
  end

  test "partial cancellation respects advance purchase and the rescheduled fixed policy cutoff" do
    apply!(open("advance", [5, 5], %{"rate_plan" => "advance_purchase"}))
    apply!(pay("advance-cash", 10, "advance"))

    assert [%{"code" => "refund_method_not_available"}] =
             batch([
               cancel("unavailable", ["r0"], %{
                 "group_id" => "advance",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert apply!(cancel("retained", ["r0"], %{"group_id" => "advance"}))["retained_cents"] == 5
    assert group("advance")["deposit_due_cents"] == 5
    apply!(open("g", [25, 25], %{"occurred_on" => "2026-12-31"}))
    apply!(pay("p", 10))
    apply!(op("move", "reschedule_group", %{"new_arrival_on" => "2027-07-01"}))
    assert group()["policy_version"] == "flex-14"

    assert apply!(cancel("cutoff", ["r0"], %{"occurred_on" => "2027-06-17"}))["refunded_cents"] ==
             5

    assert apply!(cancel("after", ["r1"], %{"occurred_on" => "2027-06-18"}))["retained_cents"] ==
             5

    assert group()["status"] == "cancelled"
  end
end
