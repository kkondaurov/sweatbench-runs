defmodule GroupStayWeb.DepositTransfersTest do
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

  defp group(id), do: read("/groups/#{id}")
  defp ledger, do: read("/ledger?on=2027-05-02")

  defp pay(id, n, group),
    do: operation(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => n})

  defp transfer(id, source, destination, amount, attrs \\ %{}),
    do:
      operation(
        id,
        "transfer_deposit",
        Map.merge(
          %{
            "source_group_id" => source,
            "destination_group_id" => destination,
            "amount_cents" => amount
          },
          attrs
        )
      )
      |> Map.delete("group_id")

  defp correction(id, type, payment, attrs \\ %{}),
    do:
      operation(id, type, Map.put(attrs, "payment_operation_id", payment))
      |> Map.delete("group_id")

  defp cancel(id, group, attrs \\ %{}),
    do: operation(id, "cancel_group", Map.put(attrs, "group_id", group))

  defp statement(id) do
    data = read("/payments/#{id}")

    assert data["recorded_cents"] ==
             Enum.sum(
               for k <-
                     ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                   do: data[k]
             )

    if Map.has_key?(data, "held_by_group"),
      do:
        assert(
          Enum.sum(Enum.map(data["held_by_group"], & &1["amount_cents"])) == data["held_cents"]
        )

    data
  end

  test "mixed funding moves in reverse allocation order, fills holes, and retries exactly" do
    batch([
      opening("seed", "seed"),
      pay("seed-pay", 1000, "seed"),
      cancel("issue", "seed", %{"refund_method" => "hotel_credit"}),
      opening("src", "src"),
      opening("dst", "dst"),
      pay("first", 3500, "src"),
      operation("use", "apply_hotel_credit", %{"group_id" => "src", "amount_cents" => 1000}),
      Map.put(pay("last", 1000, "src"), "occurred_on", "2026-01-01"),
      pay("dst-pay", 3500, "dst")
    ])

    before = ledger()

    op =
      transfer("move", "src", "dst", 2200, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 2
      })

    assert [result] = batch([op])

    assert result == %{
             "operation_id" => "move",
             "status" => "applied",
             "source_group_id" => "src",
             "destination_group_id" => "dst",
             "amount_cents" => 2200,
             "source_outstanding_deposit_cents" => 2700,
             "destination_outstanding_deposit_cents" => 300,
             "source_revision" => 5,
             "destination_revision" => 3
           }

    assert ledger() == before

    assert Enum.map(group("src")["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {3300, 0},
             {0, 0}
           ]

    assert Enum.map(group("dst")["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {4000, 0},
             {700, 1000}
           ]

    assert statement("first")["held_by_group"] == [
             %{"group_id" => "dst", "amount_cents" => 200},
             %{"group_id" => "src", "amount_cents" => 3300}
           ]

    refute Map.has_key?(statement("dst-pay"), "held_by_group")
    state = {group("src"), group("dst"), ledger()}
    assert batch([op]) == [result]
    assert read("/operations/move") == result
    assert {group("src"), group("dst"), ledger()} == state
    assert [%{"code" => "operation_id_conflict"}] = batch([Map.put(op, "amount_cents", 2100)])
    # The most recently drawn cash became the newest destination allocation.
    batch([transfer("back", "dst", "src", 200)])
    assert statement("first")["held_by_group"] == [%{"group_id" => "src", "amount_cents" => 3500}]
    assert ledger() == before
  end

  test "existence, revision and transfer validation precedence is atomic and durable" do
    batch([
      opening("src", "src"),
      opening("dst", "dst"),
      pay("p", 100, "src"),
      Map.put(opening("other", "other"), "guest_id", "other"),
      opening("inactive", "inactive"),
      cancel("cancel", "inactive")
    ])

    before = {group("src"), group("dst"), ledger()}

    cases = [
      {transfer("missing-source", "missing", "absent", 1),
       %{"code" => "group_not_found", "group_id" => "missing"}},
      {transfer("missing-dst", "src", "absent", 1, %{"expected_revision" => 0}),
       %{"code" => "group_not_found", "group_id" => "absent"}},
      {transfer("source-stale", "src", "dst", -1, %{
         "expected_revision" => 1,
         "destination_expected_revision" => 0
       }),
       %{
         "code" => "stale_revision",
         "group_id" => "src",
         "expected_revision" => 1,
         "actual_revision" => 2
       }},
      {transfer("dest-stale", "src", "dst", -1, %{
         "expected_revision" => 2,
         "destination_expected_revision" => 0
       }),
       %{
         "code" => "stale_revision",
         "group_id" => "dst",
         "expected_revision" => 0,
         "actual_revision" => 1
       }},
      {transfer("same", "src", "src", 1), %{"code" => "invalid_transfer"}},
      {transfer("guest", "src", "other", 1), %{"code" => "invalid_transfer"}},
      {transfer("inactive-source", "inactive", "dst", 1),
       %{"code" => "group_not_active", "group_id" => "inactive"}},
      {transfer("inactive-dst", "src", "inactive", 1),
       %{"code" => "group_not_active", "group_id" => "inactive"}},
      {transfer("held", "src", "dst", 101), %{"code" => "transfer_exceeds_held_funding"}}
    ]

    for {op, expected} <- cases do
      assert [result] = batch([op])
      assert Map.take(result, Map.keys(expected)) == expected
      assert result["status"] == "rejected"
      assert {group("src"), group("dst"), ledger()} == before
    end

    for {amount, i} <- Enum.with_index([0, -1, nil, "1", 1.0, true]) do
      assert [%{"code" => "invalid_amount"}] =
               batch([transfer("amount-#{i}", "src", "dst", amount)])
    end

    for key <- ~w(source_group_id destination_group_id amount_cents occurred_on) do
      assert [%{"code" => "invalid_operation"}] =
               batch([Map.delete(transfer("missing-#{key}", "src", "dst", 1), key)])
    end

    batch([pay("fill", 6000, "dst")])
    rejected = transfer("full", "src", "dst", 1)
    assert [result = %{"code" => "transfer_exceeds_outstanding"}] = batch([rejected])
    batch([correction("reduce", "reduce_cash_payment", "fill", %{"amount_cents" => 1})])
    assert batch([rejected]) == [result]
    assert [%{"status" => "applied"}] = batch([transfer("now-valid", "src", "dst", 1)])
  end

  test "reductions follow global allocation order and advance each affected group once" do
    [_, _, _, original | _] =
      batch([
        opening("a", "a"),
        opening("b", "b"),
        opening("c", "c"),
        pay("p", 5000, "a"),
        transfer("ab", "a", "b", 3000),
        transfer("bc", "b", "c", 1000)
      ])

    revisions = for id <- ~w(a b c), into: %{}, do: {id, group(id)["revision"]}

    op =
      correction("reduce", "reduce_cash_payment", "p", %{
        "amount_cents" => 1500,
        "expected_revision" => revisions["a"]
      })

    assert [result = %{"revision" => 4, "outstanding_deposit_cents" => 4000}] = batch([op])
    assert Enum.map(~w(a b c), &group(&1)["cash_paid_cents"]) == [2000, 1500, 0]
    for id <- ~w(a b c), do: assert(group(id)["revision"] == revisions[id] + 1)
    assert batch([op]) == [result]
    assert batch([pay("p", 5000, "a")]) == [original]
    assert statement("p")["reduced_cents"] == 1500
    # Original group remains addressed even when all remaining cash is elsewhere.
    batch([transfer("rest", "a", "b", 2000), cancel("close-original", "a")])
    prior = group("a")["revision"]

    assert [%{"revision" => rev}] =
             batch([
               correction("all", "reduce_cash_payment", "p", %{
                 "amount_cents" => 3500,
                 "expected_revision" => prior
               })
             ])

    assert rev == prior + 1
    assert statement("p")["held_by_group"] == []
    assert ledger()["cash_reduced_cents"] == 5000
  end

  test "transferred cash settles under destination policy and chargebacks reconcile every group" do
    batch([
      opening("a", "a"),
      opening("b", "b"),
      Map.put(opening("c", "c"), "rate_plan", "advance_purchase"),
      opening("d", "d"),
      pay("p", 5000, "a"),
      transfer("ab", "a", "b", 1000),
      transfer("ac", "a", "c", 1000),
      transfer("ad", "a", "d", 1000),
      cancel("refund", "b"),
      cancel("retain", "c"),
      cancel("convert", "d", %{"refund_method" => "hotel_credit"}),
      correction("reduce", "reduce_cash_payment", "p", %{"amount_cents" => 500})
    ])

    s = statement("p")

    assert {s["held_cents"], s["refunded_cents"], s["retained_cents"],
            s["converted_to_credit_cents"], s["reduced_cents"]} == {1500, 1000, 1000, 1000, 500}

    revisions = for id <- ~w(a b c d), into: %{}, do: {id, group(id)["revision"]}

    assert [%{"charged_back_cents" => 4500}] =
             batch([correction("cb", "charge_back_payment", "p")])

    for id <- ~w(a b c d), do: assert(group(id)["revision"] == revisions[id] + 1)
    assert statement("p")["held_by_group"] == []

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 500,
             "cash_charged_back_cents" => 4500,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    for id <- ~w(a b c d) do
      stored = Repo.get!(GroupStay.Group, id)

      assert stored.refunded_cents >= 0 and stored.retained_cents >= 0 and
               stored.cash_converted_to_credit_cents >= 0
    end
  end

  test "transferred credit pauses expiry and restores original lots with shortfall absorption" do
    for {suffix, cancel_on} <- [{"restore", "2028-05-03"}, {"consume", "2028-07-01"}] do
      seed = "seed-#{suffix}"
      src = "src-#{suffix}"
      dst = "dst-#{suffix}"

      future = fn id ->
        opening(id, id)
        |> Map.merge(%{"arrival_on" => "2028-07-01", "departure_on" => "2028-07-03"})
      end

      batch([
        opening(seed, seed),
        pay("p-#{suffix}", 100, seed),
        cancel("issue-#{suffix}", seed, %{"refund_method" => "hotel_credit"}),
        future.(src),
        future.(dst),
        operation("use-#{suffix}", "apply_hotel_credit", %{
          "group_id" => src,
          "amount_cents" => 110
        })
      ])

      before = read("/ledger?on=2028-05-03")
      batch([transfer("move-#{suffix}", src, dst, 110, %{"occurred_on" => "2028-05-03"})])
      assert read("/ledger?on=2028-05-03") == before
      revisions = {group(src), group(dst)}
      batch([correction("cb-#{suffix}", "charge_back_payment", "p-#{suffix}")])
      assert {group(src), group(dst)} == revisions
      assert read("/ledger?on=2028-05-03")["credit_shortfall_cents"] == 110
      batch([cancel("return-#{suffix}", dst, %{"occurred_on" => cancel_on})])
      assert read("/ledger?on=2028-05-03")["credit_liability_cents"] == 0
      assert read("/ledger?on=2028-05-03")["credit_shortfall_cents"] == 0
    end
  end

  test "transferred credit returns to the original lot without bonus and expires on its original date" do
    for {suffix, on, available} <- [{"live", "2028-05-01", 110}, {"expired", "2028-05-03", 0}] do
      seed = "seed-#{suffix}"
      src = "src-#{suffix}"
      dst = "dst-#{suffix}"

      future = fn id ->
        opening(id, id)
        |> Map.merge(%{
          "arrival_on" => "2028-07-01",
          "departure_on" => "2028-07-03",
          "guest_id" => suffix
        })
      end

      batch([
        Map.put(opening(seed, seed), "guest_id", suffix),
        pay("p-#{suffix}", 100, seed),
        cancel("issue-#{suffix}", seed, %{"refund_method" => "hotel_credit"}),
        future.(src),
        future.(dst),
        operation("use-#{suffix}", "apply_hotel_credit", %{
          "group_id" => src,
          "amount_cents" => 110
        }),
        transfer("move-#{suffix}", src, dst, 110, %{"occurred_on" => on}),
        cancel("return-#{suffix}", dst, %{"occurred_on" => on, "refund_method" => "hotel_credit"})
      ])

      balance = read("/guests/#{suffix}/credit?on=#{on}")
      assert balance["available_cents"] == available

      if available > 0 do
        assert balance["lots"] == [
                 %{
                   "source_operation_id" => "issue-#{suffix}",
                   "remaining_cents" => 110,
                   "expires_on" => "2028-05-01"
                 }
               ]
      else
        assert balance["lots"] == []
      end

      assert read("/operations/return-#{suffix}")["credit_issued_cents"] == 0
    end
  end

  test "transfers skip cancelled rooms and immediate destination settlement uses the moved payment" do
    batch([
      opening("src", "src"),
      opening("dst", "dst"),
      pay("p", 5000, "src"),
      operation("src-b", "cancel_rooms", %{"group_id" => "src", "room_ids" => ["b"]}),
      operation("dst-a", "cancel_rooms", %{"group_id" => "dst", "room_ids" => ["a"]}),
      transfer("move", "src", "dst", 2000)
    ])

    assert Enum.map(group("dst")["rooms"], & &1["cash_paid_cents"]) == [0, 2000]
    assert Enum.map(group("src")["rooms"], & &1["cash_paid_cents"]) == [2000, 0]

    assert [%{"credit_issued_cents" => 2200}] =
             batch([cancel("convert", "dst", %{"refund_method" => "hotel_credit"})])

    assert statement("p")["converted_to_credit_cents"] == 2000
    batch([correction("cb", "charge_back_payment", "p")])
    assert ledger()["credit_liability_cents"] == 0
    assert statement("p")["charged_back_cents"] == 5000
  end

  test "transfer and cross-group correction audit failures roll back all state" do
    batch([opening("a", "a"), opening("b", "b"), pay("p", 5000, "a")])

    for op <- [
          transfer("fail", "a", "b", 3000),
          correction("fail", "reduce_cash_payment", "p", %{"amount_cents" => 4000}),
          correction("fail", "charge_back_payment", "p")
        ] do
      if op["type"] == "reduce_cash_payment", do: batch([transfer("move", "a", "b", 3000)])

      before =
        {group("a"), group("b"), ledger(), statement("p"), Repo.all(GroupStay.CashAllocation),
         Repo.query!("SELECT * FROM allocation_clock").rows}

      Repo.query!(
        "CREATE TRIGGER fail_operation BEFORE INSERT ON operations WHEN NEW.operation_id = 'fail' BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
      )

      assert_error_sent 500, fn -> batch([op]) end

      assert {group("a"), group("b"), ledger(), statement("p"),
              Repo.all(GroupStay.CashAllocation),
              Repo.query!("SELECT * FROM allocation_clock").rows} == before

      assert Reservations.get_operation("fail") == nil
      Repo.query!("DROP TRIGGER fail_operation")
    end
  end
end
