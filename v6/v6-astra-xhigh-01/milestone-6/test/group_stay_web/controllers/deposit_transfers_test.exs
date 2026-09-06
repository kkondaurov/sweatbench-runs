defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerFixtures
  import Ecto.Query
  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CreditAllocation,
    CreditLot,
    FundingAllocation,
    Group,
    Payment,
    PaymentSettlement,
    Room
  }

  test "mixed funding is drawn newest first and fills active destination rooms in original order",
       %{conn: conn} do
    seed_credit(conn, 100)
    apply!(conn, opening("source", 4))
    apply!(conn, opening("destination", 4, %{"property_id" => "other-property"}))
    apply!(conn, op("cancel_rooms", "destination", %{"room_ids" => ["r1"]}))
    first = op("record_cash_payment", "source", %{"amount_cents" => 150})
    last = op("record_cash_payment", "source", %{"amount_cents" => 50})
    untouched = op("record_cash_payment", "destination", %{"amount_cents" => 20})
    original = apply!(conn, first)
    apply!(conn, op("apply_hotel_credit", "source", %{"amount_cents" => 80}))
    apply!(conn, last)
    apply!(conn, untouched)
    before = ledger(conn)

    transfer =
      transfer("source", "destination", 190, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 3
      })

    result = apply!(conn, transfer)

    assert result == %{
             "operation_id" => transfer["operation_id"],
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 190,
             "source_outstanding_deposit_cents" => 310,
             "destination_outstanding_deposit_cents" => 90,
             "source_revision" => 5,
             "destination_revision" => 4
           }

    assert balances(conn, "source") == [{90, 0}, {0, 0}, {0, 0}, {0, 0}]
    assert balances(conn, "destination") == [{0, 0}, {70, 30}, {50, 50}, {10, 0}]

    assert statement(conn, first)["held_by_group"] == [
             held("destination", 60),
             held("source", 90)
           ]

    assert statement(conn, last)["held_by_group"] == [held("destination", 50)]
    refute Map.has_key?(statement(conn, untouched), "held_by_group")
    assert ledger(conn) == before
    snapshot = snapshot()
    assert apply!(conn, transfer) == result
    assert apply!(conn, first) == original
    assert snapshot() == snapshot

    assert get(conn, "/api/v1/operations/#{transfer["operation_id"]}") |> json_response(200) == %{
             "data" => result
           }

    # New allocations retain draw order, including the partial final cash slice.
    lots = Repo.all(CreditLot)
    [lot] = lots

    assert Repo.all(
             from a in FundingAllocation,
               where: a.group_id == "destination",
               order_by: a.id,
               select: {a.payment_operation_id, a.credit_lot_id, a.amount_cents}
           ) == [
             {untouched["operation_id"], nil, 20},
             {last["operation_id"], nil, 50},
             {nil, lot.id, 30},
             {nil, lot.id, 50},
             {first["operation_id"], nil, 50},
             {first["operation_id"], nil, 10}
           ]
  end

  test "reductions follow allocation creation order across repeated transfers and revise each affected group once",
       %{conn: conn} do
    for id <- ["a", "b", "c", "unaffected"], do: apply!(conn, opening(id, 2))
    payment = op("record_cash_payment", "a", %{"amount_cents" => 200})
    original = apply!(conn, payment)
    apply!(conn, transfer("a", "b", 100))
    apply!(conn, transfer("b", "c", 40))
    apply!(conn, transfer("c", "a", 10))

    reduction =
      target("reduce_cash_payment", payment, %{"amount_cents" => 75, "expected_revision" => 4})

    assert %{"group_id" => "a", "revision" => 5, "outstanding_deposit_cents" => 100} =
             apply!(conn, reduction)

    assert balances(conn, "a") == [{100, 0}, {0, 0}]
    assert balances(conn, "b") == [{25, 0}, {0, 0}]
    assert balances(conn, "c") == [{0, 0}, {0, 0}]
    assert revisions(conn, ["a", "b", "c", "unaffected"]) == [5, 4, 4, 1]
    assert statement(conn, payment)["held_by_group"] == [held("a", 100), held("b", 25)]
    before = snapshot()

    assert %{"code" => "stale_revision", "group_id" => "a", "actual_revision" => 5} =
             submit(conn, target("charge_back_payment", payment, %{"expected_revision" => 4}))

    assert snapshot() == before
    assert apply!(conn, payment) == original
    apply!(conn, target("reduce_cash_payment", payment, %{"amount_cents" => 120}))
    assert revisions(conn, ["a", "b", "c"]) == [6, 5, 4]

    assert %{"charged_back_cents" => 5, "revision" => 7} =
             apply!(conn, target("charge_back_payment", payment))

    assert statement(conn, payment)["held_by_group"] == []
    assert ledger(conn)["cash_reduced_cents"] == 195
    assert ledger(conn)["cash_charged_back_cents"] == 5
  end

  test "corrections address a cancelled original group while removing transferred held cash", %{
    conn: conn
  } do
    apply!(conn, opening("source", 1))
    apply!(conn, opening("destination", 1))
    payment = op("record_cash_payment", "source", %{"amount_cents" => 100})
    apply!(conn, payment)
    apply!(conn, transfer("source", "destination", 100))
    apply!(conn, op("cancel_group", "source"))

    assert %{"revision" => 5, "outstanding_deposit_cents" => 0} =
             apply!(
               conn,
               target("reduce_cash_payment", payment, %{
                 "amount_cents" => 40,
                 "expected_revision" => 4
               })
             )

    assert revisions(conn, ["source", "destination"]) == [5, 3]

    assert %{"revision" => 6, "outstanding_deposit_cents" => 0, "charged_back_cents" => 60} =
             apply!(conn, target("charge_back_payment", payment, %{"expected_revision" => 5}))

    assert revisions(conn, ["source", "destination"]) == [6, 4]
    assert group(conn, "destination")["outstanding_deposit_cents"] == 100
  end

  test "chargebacks reclassify settlement at each destination and revise held and settled groups",
       %{conn: conn} do
    apply!(conn, opening("source", 5))
    for id <- ["refunded", "converted", "held", "credit-user"], do: apply!(conn, opening(id, 2))
    apply!(conn, opening("retained", 1, %{"rate_plan" => "advance_purchase"}))
    payment = op("record_cash_payment", "source", %{"amount_cents" => 500})
    original = apply!(conn, payment)
    apply!(conn, target("reduce_cash_payment", payment, %{"amount_cents" => 50}))

    for id <- ["refunded", "retained", "converted", "held"],
        do: apply!(conn, transfer("source", id, 100))

    apply!(conn, op("cancel_group", "refunded"))
    apply!(conn, op("cancel_group", "retained"))
    apply!(conn, op("cancel_group", "converted", %{"refund_method" => "hotel_credit"}))
    apply!(conn, op("apply_hotel_credit", "credit-user", %{"amount_cents" => 80}))
    credit_user = group(conn, "credit-user")

    assert Map.take(
             statement(conn, payment),
             ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents)
           ) == %{
             "held_cents" => 150,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 100,
             "reduced_cents" => 50
           }

    chargeback = target("charge_back_payment", payment, %{"expected_revision" => 7})

    assert %{"revision" => 8, "charged_back_cents" => 450, "outstanding_deposit_cents" => 500} =
             apply!(conn, chargeback)

    assert revisions(conn, ["source", "refunded", "retained", "converted", "held"]) == [
             8,
             4,
             4,
             4,
             3
           ]

    assert group(conn, "credit-user") == credit_user

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 50,
             "cash_charged_back_cents" => 450,
             "credit_liability_cents" => 80,
             "credit_shortfall_cents" => 80
           }

    assert statement(conn, payment)["held_by_group"] == []
    state = snapshot()
    assert apply!(conn, payment) == original
    assert apply!(conn, chargeback)["revision"] == 8
    assert snapshot() == state
    apply!(conn, op("cancel_group", "credit-user"))
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  test "transferred cash uses destination policy and rounding follows its new allocation order",
       %{conn: conn} do
    apply!(conn, opening("source", 1, %{"rate_plan" => "advance_purchase"}))
    apply!(conn, opening("destination", 2))
    first = op("record_cash_payment", "source", %{"amount_cents" => 1})
    last = op("record_cash_payment", "source", %{"amount_cents" => 4})
    apply!(conn, first)
    apply!(conn, last)
    apply!(conn, transfer("source", "destination", 5))

    assert %{"credit_issued_cents" => 6} =
             apply!(conn, op("cancel_group", "destination", %{"refund_method" => "hotel_credit"}))

    # Four cents moved first; the later one-cent slice gets the half-cent bonus.
    apply!(conn, target("charge_back_payment", first))
    assert credit(conn)["available_cents"] == 4
    assert revisions(conn, ["source", "destination"]) == [5, 4]
    apply!(conn, target("charge_back_payment", last))
    assert credit(conn)["available_cents"] == 0
  end

  test "credit transfers preserve lots and paused expiry, restoring only to the original expiry",
       %{conn: conn} do
    seed_credit(conn, 100)

    for id <- ["source", "destination"],
        do:
          apply!(
            conn,
            opening(id, 2, %{"arrival_on" => "2029-02-01", "departure_on" => "2029-02-02"})
          )

    apply!(conn, op("apply_hotel_credit", "source", %{"amount_cents" => 110}))
    before = ledger(conn, "2028-01-01")
    apply!(conn, transfer("source", "destination", 110, %{"occurred_on" => "2028-01-01"}))
    assert ledger(conn, "2028-01-01") == before

    assert Repo.all(CreditAllocation) |> Enum.map(&{&1.group_id, &1.amount_cents}) == [
             {"destination", 110}
           ]

    assert %{"credit_issued_cents" => 0, "refunded_cents" => 0} =
             apply!(
               conn,
               op("cancel_rooms", "destination", %{
                 "room_ids" => ["r2"],
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2027-11-01"
               })
             )

    assert credit(conn, "2027-11-01")["lots"] |> Enum.map(& &1["expires_on"]) == ["2027-11-01"]
    assert credit(conn, "2027-11-01")["available_cents"] == 10
    apply!(conn, op("cancel_group", "destination", %{"occurred_on" => "2028-01-01"}))
    assert ledger(conn, "2028-01-01")["credit_liability_cents"] == 0
    assert credit(conn, "2028-01-01")["available_cents"] == 0
  end

  test "transferred shortfalled credit absorbs restorations before expiry and is consumed normally",
       %{conn: conn} do
    payment = seed_credit(conn, 100)

    for id <- ["source", "destination"],
        do:
          apply!(
            conn,
            opening(id, 2, %{"arrival_on" => "2029-02-01", "departure_on" => "2029-02-02"})
          )

    apply!(conn, op("apply_hotel_credit", "source", %{"amount_cents" => 110}))
    apply!(conn, target("charge_back_payment", payment))
    before = ledger(conn, "2028-01-01")
    apply!(conn, transfer("source", "destination", 110, %{"occurred_on" => "2028-01-01"}))
    assert ledger(conn, "2028-01-01") == before

    apply!(
      conn,
      op("cancel_rooms", "destination", %{"room_ids" => ["r1"], "occurred_on" => "2028-01-01"})
    )

    assert [%{unrecovered_clawback_cents: 10, remaining_cents: 0}] = Repo.all(CreditLot)
    assert ledger(conn, "2028-01-01")["credit_shortfall_cents"] == 10
    apply!(conn, op("cancel_group", "destination", %{"occurred_on" => "2029-02-01"}))
    assert ledger(conn, "2029-02-01")["credit_shortfall_cents"] == 0
    assert ledger(conn, "2029-02-01")["credit_liability_cents"] == 0
  end

  test "transfer validations are atomic and resolve existence then both revisions before domain rules",
       %{conn: conn} do
    apply!(conn, opening("source", 1))
    apply!(conn, opening("destination", 1))
    apply!(conn, opening("other-guest", 1, %{"guest_id" => "other"}))
    apply!(conn, opening("cancelled", 1))
    apply!(conn, op("cancel_group", "cancelled"))
    apply!(conn, op("record_cash_payment", "source", %{"amount_cents" => 100}))
    apply!(conn, op("record_cash_payment", "destination", %{"amount_cents" => 50}))
    before = snapshot()

    for {operation, expected} <- [
          {transfer("missing-source", "missing-destination", 1),
           %{"code" => "group_not_found", "group_id" => "missing-source"}},
          {transfer("source", "missing-destination", 1, %{"expected_revision" => 0}),
           %{"code" => "group_not_found", "group_id" => "missing-destination"}},
          {transfer("source", "destination", -1, %{
             "expected_revision" => 1,
             "destination_expected_revision" => 1
           }),
           %{
             "code" => "stale_revision",
             "group_id" => "source",
             "expected_revision" => 1,
             "actual_revision" => 2
           }},
          {transfer("source", "other-guest", -1, %{
             "expected_revision" => 2,
             "destination_expected_revision" => 0
           }),
           %{
             "code" => "stale_revision",
             "group_id" => "other-guest",
             "expected_revision" => 0,
             "actual_revision" => 1
           }},
          {transfer("source", "source", 1, %{"destination_expected_revision" => 0}),
           %{"code" => "stale_revision", "group_id" => "source"}},
          {transfer("source", "source", 1), %{"code" => "invalid_transfer"}},
          {transfer("source", "other-guest", 1), %{"code" => "invalid_transfer"}},
          {transfer("source", "cancelled", 1),
           %{"code" => "group_not_active", "group_id" => "cancelled"}},
          {transfer("cancelled", "source", 1),
           %{"code" => "group_not_active", "group_id" => "cancelled"}},
          {transfer("source", "destination", 101), %{"code" => "transfer_exceeds_held_funding"}},
          {transfer("source", "destination", 51), %{"code" => "transfer_exceeds_outstanding"}}
        ] do
      result = submit(conn, operation)
      assert result["status"] == "rejected"
      assert Map.take(result, Map.keys(expected)) == expected
      assert snapshot() == before
    end

    for amount <- [0, -1, nil, "1", 1.5, true, [], %{}] do
      assert %{"code" => "invalid_amount"} =
               submit(conn, transfer("source", "destination", amount))
    end

    for key <- ~w(source_group_id destination_group_id amount_cents occurred_on) do
      assert %{"code" => "invalid_operation"} =
               submit(conn, Map.delete(transfer("source", "destination", 1), key))
    end

    assert snapshot() == before
  end

  test "same-batch visibility and durable rejections preserve the original result and permit later operations",
       %{conn: conn} do
    rejected = transfer("source", "destination", 1)
    stale = transfer("source", "destination", 10, %{"expected_revision" => 1})
    payment = op("record_cash_payment", "source", %{"amount_cents" => 100})

    first =
      transfer("source", "destination", 40, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    second =
      transfer("source", "destination", 60, %{
        "expected_revision" => 3,
        "destination_expected_revision" => 2
      })

    [missing, _, _, _, moved, stale_result, moved_again] =
      batch(conn, [
        rejected,
        opening("source", 1),
        opening("destination", 1),
        payment,
        first,
        stale,
        second
      ])

    assert missing["code"] == "group_not_found"
    assert moved["source_revision"] == 3
    assert stale_result["actual_revision"] == 3
    assert moved_again["destination_revision"] == 3
    before = snapshot()

    assert batch(conn, [rejected, first, stale, second]) == [
             missing,
             moved,
             stale_result,
             moved_again
           ]

    assert %{"code" => "operation_id_conflict"} =
             submit(conn, Map.put(stale, "expected_revision", 4))

    assert snapshot() == before
  end

  test "transfers merge existing applied lots while retaining each lot's settlement provenance",
       %{conn: conn} do
    first = seed_credit(conn, 100)
    apply!(conn, opening("second-credit-source", 1))
    second = op("record_cash_payment", "second-credit-source", %{"amount_cents" => 100})
    apply!(conn, second)

    apply!(
      conn,
      op("cancel_group", "second-credit-source", %{
        "refund_method" => "hotel_credit",
        "occurred_on" => "2026-11-02"
      })
    )

    for id <- ["source", "destination"], do: apply!(conn, opening(id, 2))

    apply!(
      conn,
      op("apply_hotel_credit", "source", %{"amount_cents" => 150, "occurred_on" => "2026-11-03"})
    )

    apply!(
      conn,
      op("apply_hotel_credit", "destination", %{
        "amount_cents" => 30,
        "occurred_on" => "2026-11-03"
      })
    )

    before = ledger(conn, "2026-11-03")
    apply!(conn, transfer("source", "destination", 120, %{"occurred_on" => "2026-11-03"}))
    assert ledger(conn, "2026-11-03") == before
    assert balances(conn, "source") == [{0, 30}, {0, 0}]
    assert balances(conn, "destination") == [{0, 100}, {0, 50}]
    refute Map.has_key?(statement(conn, first), "held_by_group")
    refute Map.has_key?(statement(conn, second), "held_by_group")

    apply!(
      conn,
      op("cancel_rooms", "destination", %{"room_ids" => ["r1"], "refund_method" => "hotel_credit"})
    )

    assert Enum.map(
             credit(conn, "2026-11-03")["lots"],
             &{&1["expires_on"], &1["remaining_cents"]}
           ) == [
             {"2027-11-01", 30},
             {"2027-11-02", 110}
           ]

    assert ledger(conn, "2026-11-03")["credit_liability_cents"] == 220
    for id <- ["source", "destination"], do: apply!(conn, op("cancel_group", id))
    assert credit(conn, "2026-11-03")["available_cents"] == 220
  end

  test "transfers preserve exact large integer cents and full destination capacity", %{conn: conn} do
    maximum = 9_223_372_036_854_775_807

    for id <- ["source", "destination"] do
      apply!(
        conn,
        opening(id, 1, %{
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "large", "nightly_rate_cents" => maximum}]
        })
      )
    end

    payment = op("record_cash_payment", "source", %{"amount_cents" => maximum})
    apply!(conn, payment)
    before = ledger(conn)

    assert %{
             "source_outstanding_deposit_cents" => ^maximum,
             "destination_outstanding_deposit_cents" => 0
           } =
             apply!(conn, transfer("source", "destination", maximum))

    assert ledger(conn) == before
    assert statement(conn, payment)["held_by_group"] == [held("destination", maximum)]

    assert %{"charged_back_cents" => ^maximum} =
             apply!(conn, target("charge_back_payment", payment))

    assert revisions(conn, ["source", "destination"]) == [4, 3]
    assert ledger(conn)["cash_charged_back_cents"] == maximum
  end

  defp opening(id, count, fields \\ %{}) do
    open_operation(
      Map.merge(
        %{
          "group_id" => id,
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => for(i <- 1..count, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500})
        },
        fields
      )
    )
  end

  defp op(type, group_id, fields \\ %{}),
    do: operation(type, Map.put(fields, "group_id", group_id))

  defp transfer(source, destination, amount, fields \\ %{}),
    do:
      operation(
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
      |> Map.delete("group_id")

  defp target(type, payment, fields \\ %{}),
    do:
      operation(type, Map.put(fields, "payment_operation_id", payment["operation_id"]))
      |> Map.delete("group_id")

  defp batch(conn, operations),
    do:
      post(conn, "/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp submit(conn, operation), do: batch(conn, [operation]) |> hd()

  defp apply!(conn, operation) do
    result = submit(conn, operation)
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp group(conn, id),
    do: get(conn, "/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp balances(conn, id),
    do: Enum.map(group(conn, id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp revisions(conn, ids), do: Enum.map(ids, &group(conn, &1)["revision"])

  defp ledger(conn, on \\ "2026-11-01"),
    do: get(conn, "/api/v1/ledger?on=#{on}") |> json_response(200) |> Map.fetch!("data")

  defp credit(conn, on \\ "2026-11-01"),
    do:
      get(conn, "/api/v1/guests/guest-22/credit?on=#{on}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp held(id, amount), do: %{"group_id" => id, "amount_cents" => amount}

  defp statement(conn, payment) do
    data =
      get(conn, "/api/v1/payments/#{payment["operation_id"]}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["recorded_cents"] ==
             Enum.sum(
               for key <-
                     ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                   do: data[key]
             )

    if Map.has_key?(data, "held_by_group"),
      do:
        assert(
          Enum.sum(Enum.map(data["held_by_group"], & &1["amount_cents"])) == data["held_cents"]
        )

    data
  end

  defp snapshot,
    do:
      Enum.map(
        [Group, Room, FundingAllocation, CreditAllocation, CreditLot, Payment, PaymentSettlement],
        &Repo.all/1
      )

  defp seed_credit(conn, amount) do
    apply!(conn, opening("credit-source", 2))
    payment = op("record_cash_payment", "credit-source", %{"amount_cents" => amount})
    apply!(conn, payment)
    apply!(conn, op("cancel_group", "credit-source", %{"refund_method" => "hotel_credit"}))
    payment
  end
end
