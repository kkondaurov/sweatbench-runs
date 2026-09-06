defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase
  import GroupStay.OperationFixtures
  alias GroupStay.{CreditEntitlement, CreditLot, Group, Operation, Repo, Room, RoomAllocation}

  test "cash and multiple credit applications fill original room order in processing order" do
    issue_source(100)

    batch([
      opening("group-81", [100, 100, 100]),
      cash("cash-first", 60),
      operation("apply_hotel_credit", %{"amount_cents" => 80}),
      cash("cash-second", 100, %{"occurred_on" => "2026-01-01"}),
      operation("apply_hotel_credit", %{"amount_cents" => 30})
    ])

    assert room_funding() == [{100, 60, 40}, {100, 60, 40}, {100, 40, 30}]
    assert group()["deposit_paid_cents"] == 270
    assert group()["outstanding_deposit_cents"] == 30
    assert group()["lodging_total_cents"] == 1500
    assert Enum.map(group()["rooms"], & &1["room_id"]) == ~w(r-0 r-1 r-2)
    assert_statement("cash-first", held_cents: 60)
    assert_statement("cash-second", held_cents: 100)
  end

  test "selected rooms settle only their funding and full cancellation settles the remainder" do
    issue_source(100)

    batch([
      opening("group-81", [100, 100, 100]),
      cash("pay", 150),
      operation("apply_hotel_credit", %{"amount_cents" => 110})
    ])

    assert [%{"cancelled_room_ids" => ["r-1"], "refunded_cents" => 50, "revision" => 4}] =
             batch([cancel_rooms(["r-1"])])

    assert room_funding() == [{100, 100, 0}, {0, 0, 0}, {100, 0, 60}]
    assert group()["status"] == "active"
    assert group()["lodging_total_cents"] == 1000
    assert group()["deposit_due_cents"] == 200
    assert group()["deposit_paid_cents"] == 160
    assert credit()["available_cents"] == 50
    assert_statement("pay", held_cents: 100, refunded_cents: 50)
    assert [%{"refunded_cents" => 100, "revision" => 5}] = batch([operation("cancel_group")])
    assert group()["status"] == "cancelled"
    assert group()["lodging_total_cents"] == 0
    assert credit()["available_cents"] == 110
    assert_statement("pay", refunded_cents: 150)
  end

  test "one bonus is rounded on selected combined cash and multiple cancellations issue distinct lots" do
    batch([opening("group-81", [3, 3, 5]), cash("pay", 11)])

    assert [%{"cancelled_room_ids" => ["r-0", "r-1"], "credit_issued_cents" => 7}] =
             batch([cancel_rooms(["r-1", "r-0"], %{"refund_method" => "hotel_credit"})])

    assert [%{"credit_issued_cents" => 6}] =
             batch([operation("cancel_group", %{"refund_method" => "hotel_credit"})])

    assert length(credit()["lots"]) == 2
    assert credit()["available_cents"] == 13
    assert ledger()["cash_converted_to_credit_cents"] == 11
    assert_statement("pay", converted_to_credit_cents: 11)
    assert [%{"charged_back_cents" => 11, "revision" => 5}] = batch([chargeback("pay")])
    assert credit()["available_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert_statement("pay", charged_back_cents: 11)
  end

  test "invalid room sets reject atomically and stale revisions precede room and refund rules" do
    batch([opening("group-81", [100, 100]), cash("pay", 150)])

    for ids <- [[], nil, "r-0", ["r-0", "r-0"], ["r-0", "unknown"], [1], [%{}]] do
      assert_rejected(cancel_rooms(ids), "invalid_rooms")
    end

    assert_rejected(cancel_rooms(["r-0"], %{"refund_method" => "bad"}), "invalid_refund_method")
    assert_rejected(cancel_rooms([], %{"expected_revision" => 1}), "stale_revision")

    assert_rejected(
      cancel_rooms([], %{"group_id" => "missing", "expected_revision" => 1}),
      "group_not_found"
    )

    batch([cancel_rooms(["r-0"])])
    assert_rejected(cancel_rooms(["r-0", "r-1"]), "invalid_rooms")
    assert group()["revision"] == 3
  end

  test "partial cancellation respects fixed policy boundaries after rescheduling and unpaid rooms" do
    for {id, booked, date, refundable} <- [
          {"old", "2026-12-31", "2028-12-18", true},
          {"new", "2027-01-01", "2028-12-02", true},
          {"late", "2027-01-01", "2028-12-03", false}
        ] do
      batch([
        opening(id, [100, 100], %{"occurred_on" => booked}),
        cash("pay-#{id}", 100, %{"group_id" => id}),
        operation("reschedule_group", %{"group_id" => id, "new_arrival_on" => "2029-01-01"})
      ])

      cancel =
        cancel_rooms(["r-0"], %{
          "group_id" => id,
          "occurred_on" => date,
          "refund_method" => "hotel_credit"
        })

      if refundable do
        assert [%{"credit_issued_cents" => 110}] = batch([cancel])
      else
        assert_rejected(cancel, "refund_method_not_available")

        assert [%{"retained_cents" => 100}] =
                 batch([
                   Map.merge(cancel, %{
                     "operation_id" => unique_operation_id(),
                     "refund_method" => "cash"
                   })
                 ])
      end

      assert [%{"refunded_cents" => 0, "retained_cents" => 0}] =
               batch([operation("cancel_group", %{"group_id" => id})])

      assert group(id)["status"] == "cancelled"
    end
  end

  test "reductions remove only their payment in reverse fill order, compose and allow refilling" do
    batch([opening("group-81", [100, 100, 100]), cash("first", 170), cash("second", 100)])

    assert [
             %{
               "amount_cents" => 50,
               "group_id" => "group-81",
               "outstanding_deposit_cents" => 80,
               "revision" => 4
             }
           ] = batch([reduction("first", 50)])

    assert room_funding() == [{100, 100, 0}, {100, 50, 0}, {100, 70, 0}]
    batch([reduction("first", 40)])
    assert room_funding() == [{100, 80, 0}, {100, 30, 0}, {100, 70, 0}]
    batch([cash("refill", 60)])
    assert room_funding() == [{100, 100, 0}, {100, 70, 0}, {100, 70, 0}]
    assert_statement("first", held_cents: 80, reduced_cents: 90)
    assert_statement("second", held_cents: 100)
    batch([reduction("first", 80)])
    assert_statement("first", reduced_cents: 170)
    assert_rejected(reduction("first", 1), "payment_not_reducible")
    assert ledger()["cash_reduced_cents"] == 170
    assert group()["outstanding_deposit_cents"] == 140
  end

  test "settled cash is excluded from reductions and cancelled groups have no reducible cash" do
    batch([opening("group-81", [100, 100, 100]), cash("pay", 250), cancel_rooms(["r-0"])])
    assert_rejected(reduction("pay", 151), "reduction_exceeds_held_cash")
    assert_rejected(reduction("pay", -1, %{"expected_revision" => 2}), "stale_revision")
    batch([reduction("pay", 150)])
    assert_statement("pay", refunded_cents: 100, reduced_cents: 150)
    assert_rejected(reduction("pay", 0), "payment_not_reducible")
    batch([operation("cancel_group")])
    assert_rejected(reduction("pay", 1), "payment_not_reducible")
    assert [%{"charged_back_cents" => 100}] = batch([chargeback("pay")])
    assert_statement("pay", reduced_cents: 150, charged_back_cents: 100)
  end

  test "payment resolution, invalid amounts and immutable rejection replay use stable codes" do
    [opened, rejected, _] =
      batch([
        opening("group-81", [100]),
        cash("rejected", 101),
        cash("pay", 50)
      ])

    for id <- [opened["operation_id"], rejected["operation_id"]] do
      assert_rejected(reduction(id, 1), "payment_not_reducible")
      assert_rejected(chargeback(id), "payment_not_chargeable")
      assert read_payment(id, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end

    for amount <- [0, -1, nil, 1.0, true, "1", [], %{}] do
      assert_rejected(reduction("pay", amount), "invalid_amount")
    end

    assert_rejected(reduction("pay", 51), "reduction_exceeds_held_cash")
    missing = reduction("future", 1)
    assert [original] = batch([missing])
    assert original["code"] == "operation_not_found"
    assert read_payment("future", 404) == %{"error" => %{"code" => "operation_not_found"}}
    batch([cash("future", 10)])
    assert batch([missing]) == [original]
    assert_rejected(Map.put(missing, "amount_cents", 2), "operation_id_conflict")
    assert_rejected(chargeback("absent"), "operation_not_found")

    for op <- [
          Map.delete(reduction("pay", 1), "payment_operation_id"),
          Map.delete(chargeback("pay"), "occurred_on")
        ] do
      assert_rejected(op, "invalid_operation")
    end
  end

  test "a chargeback reclassifies all remaining cash dispositions and preserves settled results" do
    payment = cash("pay", 500)

    [_, original | _] =
      batch([
        opening("group-81", [100, 100, 100, 100, 100]),
        payment,
        cancel_rooms(["r-0"]),
        cancel_rooms(["r-1"], %{"occurred_on" => "2026-11-27"}),
        cancel_rooms(["r-2"], %{"refund_method" => "hotel_credit"}),
        reduction("pay", 50)
      ])

    assert_statement("pay",
      held_cents: 150,
      refunded_cents: 100,
      retained_cents: 100,
      converted_to_credit_cents: 100,
      reduced_cents: 50
    )

    charge = chargeback("pay", %{"expected_revision" => 6})
    assert [result] = batch([charge])

    assert result == %{
             "operation_id" => charge["operation_id"],
             "status" => "applied",
             "payment_operation_id" => "pay",
             "group_id" => "group-81",
             "charged_back_cents" => 450,
             "outstanding_deposit_cents" => 200,
             "revision" => 7
           }

    assert_statement("pay", reduced_cents: 50, charged_back_cents: 450)

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

    assert room_funding() == [{0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {100, 0, 0}, {100, 0, 0}]
    before = snapshot()
    assert batch([payment, charge]) == [original, result]
    assert snapshot() == before
    assert_rejected(chargeback("pay"), "payment_not_chargeable")
    assert_rejected(reduction("pay", 1), "payment_not_reducible")
    assert_rejected(chargeback("pay", %{"expected_revision" => 6}), "stale_revision")
  end

  test "fully reduced payments cannot be charged back and chargebacks derive their group" do
    batch([opening("group-81", [100]), cash("pay", 100)])

    assert_rejected(
      chargeback("pay", %{"group_id" => "unrelated", "expected_revision" => 1}),
      "stale_revision"
    )

    batch([reduction("pay", 100, %{"group_id" => "unrelated"})])
    assert_rejected(chargeback("pay"), "payment_not_chargeable")
    assert group()["revision"] == 3
  end

  test "entitlements telescope by payment funding order independently of room order" do
    batch([
      opening("group-81", [5, 5]),
      cash("z-first", 5),
      cash("a-second", 5),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    assert credit()["available_cents"] == 11
    batch([chargeback("a-second")])
    assert credit()["available_cents"] == 6
    assert ledger()["credit_liability_cents"] == 6
    batch([chargeback("z-first")])
    assert credit()["available_cents"] == 0
    assert ledger()["cash_charged_back_cents"] == 10
  end

  test "clawbacks use remaining fungible credit first and leave funded groups unchanged" do
    batch([
      opening("group-81", [5, 5]),
      cash("first", 5),
      cash("second", 5),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("target", [8]),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 8})
    ])

    target = group("target")
    assert credit()["available_cents"] == 3
    batch([chargeback("first")])
    assert credit()["available_cents"] == 0
    assert ledger()["credit_shortfall_cents"] == 3
    assert ledger()["credit_liability_cents"] == 8
    assert group("target") == target
    batch([chargeback("second")])
    assert ledger()["credit_shortfall_cents"] == 8
    assert ledger()["credit_liability_cents"] == 8
    assert group("target") == target
    batch([operation("cancel_group", %{"group_id" => "target"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert credit()["available_cents"] == 0
  end

  test "unrecovered clawbacks may exceed the credit still applied to active rooms" do
    issue_source(100)

    batch([
      opening("target", [70, 40]),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110}),
      cancel_rooms(["r-0"], %{"group_id" => "target", "occurred_on" => "2026-11-27"}),
      chargeback("source-pay")
    ])

    assert ledger()["credit_shortfall_cents"] == 40
    assert ledger()["credit_liability_cents"] == 40
    batch([operation("cancel_group", %{"group_id" => "target"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert credit()["available_cents"] == 0
  end

  for {date, available} <- [{"2027-11-26", 55}, {"2027-11-27", 0}] do
    test "shortfall restoration on #{date} absorbs before checking original expiry" do
      batch([
        opening("group-81", [50, 50]),
        cash("first", 50),
        cash("second", 50),
        operation("cancel_group", %{"refund_method" => "hotel_credit"}),
        opening("target", [105], %{"arrival_on" => "2029-12-10", "departure_on" => "2029-12-11"}),
        operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 105}),
        chargeback("first")
      ])

      assert ledger()["credit_shortfall_cents"] == 50
      assert ledger()["credit_liability_cents"] == 105

      batch([
        operation("cancel_group", %{"group_id" => "target", "occurred_on" => unquote(date)})
      ])

      assert ledger(unquote(date))["credit_shortfall_cents"] == 0

      assert credit(unquote(date))["available_cents"] ==
               unquote(available)

      assert ledger(unquote(date))["credit_liability_cents"] ==
               unquote(available)

      assert Repo.one(CreditLot).unrecovered_clawback_cents == 0
    end
  end

  test "nonrefundable consumption reduces current shortfall without restoring credit" do
    issue_source(100)

    batch([
      opening("target", [50, 60]),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110}),
      chargeback("source-pay")
    ])

    assert ledger()["credit_shortfall_cents"] == 110
    batch([cancel_rooms(["r-0"], %{"group_id" => "target", "occurred_on" => "2026-11-27"})])
    assert ledger()["credit_shortfall_cents"] == 60
    assert ledger()["credit_liability_cents"] == 60
    batch([operation("cancel_group", %{"group_id" => "target", "occurred_on" => "2026-11-27"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
  end

  test "partial cancellation and reductions are durably replayed and statements never write" do
    payment = cash(" Payment + café ", 150)
    cancel = cancel_rooms(["r-0"])
    reduce = reduction(payment["operation_id"], 20)
    ops = [opening("group-81", [100, 100]), payment, cancel, reduce]
    results = batch(ops)
    before = snapshot()
    assert batch(Enum.reverse(ops)) == Enum.reverse(results)

    assert_statement(payment["operation_id"],
      held_cents: 30,
      refunded_cents: 100,
      reduced_cents: 20
    )

    assert snapshot() == before
    assert_rejected(Map.put(cancel, "room_ids", ["r-1"]), "operation_id_conflict")
    assert_rejected(Map.put(reduce, "amount_cents", 21), "operation_id_conflict")
  end

  test "an audit failure rolls back chargeback allocations, entitlements, balances and revision" do
    issue_source(100)

    batch([
      opening("target", [110]),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110})
    ])

    Repo.query!("""
    CREATE TRIGGER fail_chargeback BEFORE INSERT ON operations WHEN NEW.type = 'charge_back_payment'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    op = chargeback("source-pay")
    before = snapshot()
    assert_error_sent 500, fn -> batch([op, cash("later", 1)]) end
    assert snapshot() == before
    Repo.query!("DROP TRIGGER fail_chargeback")
    assert [%{"charged_back_cents" => 100}] = batch([op])
  end

  test "refilling an earlier room does not move a later payment ahead in bonus attribution" do
    batch([
      opening("group-81", [5, 5]),
      cash("first", 5),
      cash("second", 5),
      reduction("first", 4),
      cash("third", 4),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    assert credit()["available_cents"] == 11
    batch([chargeback("second")])
    assert credit()["available_cents"] == 5
    batch([chargeback("first")])
    assert credit()["available_cents"] == 4
    assert_statement("first", reduced_cents: 4, charged_back_cents: 1)
    batch([chargeback("third")])
    assert credit()["available_cents"] == 0
  end

  test "shortfall is capped independently for each lot across several active groups" do
    issue_source(100)

    batch([
      opening("other-source", [100]),
      cash("other-pay", 100, %{"group_id" => "other-source"}),
      operation("cancel_group", %{
        "group_id" => "other-source",
        "refund_method" => "hotel_credit",
        "occurred_on" => "2026-11-25"
      }),
      opening("target", [70, 40]),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110}),
      opening("another-target", [110]),
      operation("apply_hotel_credit", %{"group_id" => "another-target", "amount_cents" => 110}),
      cancel_rooms(["r-0"], %{"group_id" => "target", "occurred_on" => "2026-11-27"}),
      chargeback("other-pay")
    ])

    assert ledger()["credit_shortfall_cents"] == 40
    assert ledger()["credit_liability_cents"] == 150
    batch([chargeback("source-pay")])
    assert ledger()["credit_shortfall_cents"] == 150
    batch([operation("cancel_group", %{"group_id" => "another-target"})])
    assert ledger()["credit_shortfall_cents"] == 40
    assert ledger()["credit_liability_cents"] == 40
  end

  test "new operations replay without consulting any current domain tables" do
    ops = [
      opening("group-81", [100, 100]),
      cash("pay", 150),
      cancel_rooms(["r-0"]),
      reduction("pay", 20),
      chargeback("pay")
    ]

    results = batch(ops)
    Repo.query!("ALTER TABLE room_allocations RENAME TO unavailable_allocations")
    Repo.query!("ALTER TABLE groups RENAME TO unavailable_groups")
    assert batch(ops) == results
  end

  test "an audit failure rolls back reductions and partial settlements before batch continuation" do
    batch([opening("group-81", [100, 100]), cash("pay", 150)])

    for type <- ~w(reduce_cash_payment cancel_rooms) do
      Repo.query!("CREATE TABLE failing_type (type TEXT)")
      Repo.query!("INSERT INTO failing_type VALUES (?)", [type])

      Repo.query!("""
      CREATE TRIGGER fail_change BEFORE INSERT ON operations
      WHEN NEW.type IN (SELECT type FROM failing_type)
      BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
      """)

      op =
        if type == "reduce_cash_payment",
          do: reduction("pay", 10),
          else: cancel_rooms(["r-0"], %{"refund_method" => "hotel_credit"})

      before = snapshot()
      assert_error_sent 500, fn -> batch([op, operation("cancel_group")]) end
      assert snapshot() == before
      Repo.query!("DROP TRIGGER fail_change")
      Repo.query!("DROP TABLE failing_type")
      assert [%{"status" => "applied"}] = batch([op])
    end
  end

  defp opening(id, deposits, overrides \\ %{}) do
    open_operation(
      Map.merge(
        %{
          "group_id" => id,
          "departure_on" => "2026-12-11",
          "rooms" =>
            Enum.with_index(deposits, fn due, index ->
              %{"room_id" => "r-#{index}", "nightly_rate_cents" => due * 5}
            end)
        },
        overrides
      )
    )
  end

  defp cash(id, amount, overrides \\ %{}),
    do:
      operation(
        "record_cash_payment",
        Map.merge(%{"operation_id" => id, "amount_cents" => amount}, overrides)
      )

  defp reduction(id, amount, overrides \\ %{}),
    do:
      operation(
        "reduce_cash_payment",
        Map.merge(%{"payment_operation_id" => id, "amount_cents" => amount}, overrides)
      )
      |> Map.delete("group_id")
      |> Map.merge(Map.take(overrides, ["group_id"]))

  defp chargeback(id, overrides \\ %{}),
    do:
      operation("charge_back_payment", Map.merge(%{"payment_operation_id" => id}, overrides))
      |> Map.delete("group_id")
      |> Map.merge(Map.take(overrides, ["group_id"]))

  defp cancel_rooms(ids, overrides \\ %{}),
    do: operation("cancel_rooms", Map.merge(%{"room_ids" => ids}, overrides))

  defp issue_source(amount) do
    batch([
      opening("source", [amount]),
      cash("source-pay", amount, %{"group_id" => "source"}),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"})
    ])
  end

  defp batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(path), do: build_conn() |> get(path) |> json_response(200) |> Map.fetch!("data")
  defp group(id \\ "group-81"), do: read("/api/v1/groups/" <> id)
  defp credit(date \\ "2026-11-26"), do: read("/api/v1/guests/guest-22/credit?on=" <> date)
  defp ledger(date \\ "2026-11-26"), do: read("/api/v1/ledger?on=" <> date)

  defp room_funding,
    do:
      Enum.map(
        group()["rooms"],
        &{&1["deposit_due_cents"], &1["cash_paid_cents"], &1["credit_paid_cents"]}
      )

  defp read_payment(id, status \\ 200),
    do:
      build_conn()
      |> get("/api/v1/payments/" <> URI.encode(id, &URI.char_unreserved?/1))
      |> json_response(status)

  defp assert_statement(id, dispositions) do
    expected =
      Map.new(
        ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
        &{&1, 0}
      )
      |> Map.merge(Map.new(dispositions, fn {key, value} -> {Atom.to_string(key), value} end))

    recorded = expected |> Map.values() |> Enum.sum()
    %{"data" => statement} = read_payment(id)

    assert statement ==
             Map.merge(expected, %{
               "payment_operation_id" => id,
               "original_group_id" => "group-81",
               "recorded_cents" => recorded
             })
  end

  defp assert_rejected(op, code) do
    before = snapshot(false)
    assert [%{"status" => "rejected", "code" => ^code}] = batch([op])
    assert snapshot(false) == before
  end

  defp snapshot(journal \\ true) do
    schemas =
      [Group, Room, RoomAllocation, CreditLot, CreditEntitlement] ++
        if(journal, do: [Operation], else: [])

    Enum.map(schemas, fn schema -> Repo.all(schema) |> Enum.sort() end)
  end
end
