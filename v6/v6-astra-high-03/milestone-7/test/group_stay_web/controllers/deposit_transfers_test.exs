defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{CashAllocation, CreditAllocation, CreditLot, Group, Repo, Reservations}

  defp opening(id, rates \\ [500, 500, 500], fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{id}",
        "type" => "open_group",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => id,
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2029-06-01",
        "departure_on" => "2029-06-02",
        "rate_plan" => "flexible",
        "rooms" =>
          Enum.with_index(rates, fn rate, i ->
            %{"room_id" => "r#{i}", "nightly_rate_cents" => rate}
          end)
      },
      fields
    )
  end

  defp op(id, type, fields),
    do: Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => "2027-01-02"}, fields)

  defp pay(id, group, amount),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount})

  defp transfer(id, source, destination, amount, fields \\ %{}),
    do:
      op(
        id,
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

  defp cancel(id, group, fields \\ %{}),
    do: op(id, "cancel_group", Map.put(fields, "group_id", group))

  defp correct(id, type, fields \\ %{}),
    do: op(id, type, Map.put(fields, "payment_operation_id", "pay"))

  defp batch(conn, ops),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp statement(conn, id) do
    data = conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

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

  defp funding(id),
    do:
      Enum.map(
        Reservations.get_group(id).rooms,
        &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
      )

  defp snapshot do
    {Enum.map([Group, CashAllocation, CreditAllocation, CreditLot], &Repo.all/1),
     Repo.query!("SELECT value FROM allocation_sequence").rows}
  end

  defp credit_source(conn) do
    batch(conn, [
      opening("issuer"),
      pay("issue-pay", "issuer", 200),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"})
    ])
  end

  test "mixed funding draws by creation order, fills destination rooms, and retries exactly", %{
    conn: conn
  } do
    credit_source(conn)

    batch(conn, [
      opening("source"),
      opening("destination"),
      pay("cash1", "source", 50),
      op("redeem", "apply_hotel_credit", %{"group_id" => "source", "amount_cents" => 120}),
      pay("cash2", "source", 100) |> Map.put("occurred_on", "2026-01-01")
    ])

    ledger = Reservations.ledger(~D[2027-01-02])

    move =
      transfer("move", "source", "destination", 200, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 1
      })

    assert [result] = batch(conn, [move])

    assert result == %{
             "operation_id" => "move",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 200,
             "source_outstanding_deposit_cents" => 230,
             "destination_outstanding_deposit_cents" => 100,
             "source_revision" => 5,
             "destination_revision" => 2
           }

    assert funding("source") == [{50, 20}, {0, 0}, {0, 0}]
    assert funding("destination") == [{100, 0}, {0, 100}, {0, 0}]
    assert Reservations.ledger(~D[2027-01-02]) == ledger
    refute Map.has_key?(statement(conn, "cash1"), "held_by_group")

    assert statement(conn, "cash2")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 100}
           ]

    before = snapshot()
    assert batch(conn, [move]) == [result]
    assert snapshot() == before
    assert conn |> get("/api/v1/operations/move") |> json_response(200) == %{"data" => result}

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(move, "amount_cents", 1)])

    # A second transfer draws the newly placed credit first, reversing its allocation order again.
    batch(conn, [transfer("back", "destination", "source", 130)])
    assert funding("source") == [{50, 50}, {30, 70}, {0, 0}]
    assert funding("destination") == [{70, 0}, {0, 0}, {0, 0}]

    assert statement(conn, "cash2")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 70},
             %{"group_id" => "source", "amount_cents" => 30}
           ]

    assert Reservations.ledger(~D[2027-01-02]) == ledger
    before = snapshot()
    assert batch(conn, [move]) == [result]
    assert snapshot() == before
  end

  test "existence and both revision guards precede domain rules; rejections preserve state", %{
    conn: conn
  } do
    batch(conn, [
      opening("s"),
      opening("d"),
      opening("other", [500], %{"guest_id" => "other"}),
      opening("closed"),
      cancel("close", "closed"),
      pay("pay", "s", 100),
      pay("full", "d", 250)
    ])

    cases = [
      {transfer("missing-source", "absent", "also-absent", 1), "group_not_found",
       %{"group_id" => "absent"}},
      {transfer("missing-dest", "s", "absent", 1, %{"expected_revision" => 0}), "group_not_found",
       %{"group_id" => "absent"}},
      {transfer("stale-source", "s", "d", -1, %{
         "expected_revision" => 0,
         "destination_expected_revision" => 0
       }), "stale_revision",
       %{"group_id" => "s", "expected_revision" => 0, "actual_revision" => 2}},
      {transfer("stale-dest", "s", "d", -1, %{
         "expected_revision" => 2,
         "destination_expected_revision" => 0
       }), "stale_revision",
       %{"group_id" => "d", "expected_revision" => 0, "actual_revision" => 2}},
      {transfer("same", "s", "s", 1), "invalid_transfer", %{}},
      {transfer("guest", "s", "other", 1), "invalid_transfer", %{}},
      {transfer("closed-source", "closed", "d", 1), "group_not_active",
       %{"group_id" => "closed"}},
      {transfer("closed-dest", "s", "closed", 1), "group_not_active", %{"group_id" => "closed"}},
      {transfer("held", "s", "d", 101), "transfer_exceeds_held_funding", %{}},
      {transfer("outstanding", "s", "d", 51), "transfer_exceeds_outstanding", %{}}
    ]

    for {request, code, details} <- cases do
      before = snapshot()
      assert [result] = batch(conn, [request])

      assert result ==
               Map.merge(
                 %{
                   "operation_id" => request["operation_id"],
                   "status" => "rejected",
                   "code" => code
                 },
                 details
               )

      assert snapshot() == before
      assert batch(conn, [request]) == [result]
    end

    for amount <- [0, -1, 1.5, "1", nil, true] do
      before = snapshot()

      assert [%{"code" => "invalid_amount"}] =
               batch(conn, [transfer("bad-#{inspect(amount)}", "s", "d", amount)])

      assert snapshot() == before
    end

    for field <- ~w(source_group_id destination_group_id amount_cents occurred_on) do
      assert [%{"code" => "invalid_operation"}] =
               batch(conn, [transfer("missing-#{field}", "s", "d", 1) |> Map.delete(field)])
    end

    assert [
             %{"source_revision" => 3, "destination_revision" => 3},
             %{"code" => "stale_revision", "actual_revision" => 3},
             %{"source_revision" => 4}
           ] =
             batch(conn, [
               transfer("valid", "s", "d", 50),
               transfer("stale-batch", "d", "s", 1, %{"expected_revision" => 2}),
               transfer("continue", "d", "s", 50)
             ])
  end

  test "reductions follow global allocation order and advance only changed and addressed groups",
       %{conn: conn} do
    payment = pay("pay", "s", 250)

    [_, _, _, original | _] =
      batch(conn, [
        opening("s"),
        opening("a"),
        opening("b"),
        payment,
        transfer("to-a", "s", "a", 150),
        transfer("to-b", "a", "b", 50)
      ])

    assert [%{"revision" => 4, "outstanding_deposit_cents" => 200}] =
             batch(conn, [
               correct("reduce", "reduce_cash_payment", %{
                 "amount_cents" => 80,
                 "expected_revision" => 3
               })
             ])

    assert funding("s") == [{100, 0}, {0, 0}, {0, 0}]
    assert funding("a") == [{70, 0}, {0, 0}, {0, 0}]
    assert funding("b") == [{0, 0}, {0, 0}, {0, 0}]
    assert Reservations.get_group("a").revision == 4
    assert Reservations.get_group("b").revision == 3

    assert statement(conn, "pay")["held_by_group"] == [
             %{"group_id" => "a", "amount_cents" => 70},
             %{"group_id" => "s", "amount_cents" => 100}
           ]

    assert [%{"revision" => 5}] =
             batch(conn, [correct("reduce-a", "reduce_cash_payment", %{"amount_cents" => 70})])

    assert Reservations.get_group("a").revision == 5
    assert Reservations.get_group("b").revision == 3

    assert statement(conn, "pay")["held_by_group"] == [
             %{"group_id" => "s", "amount_cents" => 100}
           ]

    assert batch(conn, [payment]) == [original]

    assert [%{"charged_back_cents" => 100, "revision" => 6}] =
             batch(conn, [correct("charge", "charge_back_payment")])

    assert statement(conn, "pay")["held_by_group"] == []

    assert %{cash_reduced_cents: 150, cash_charged_back_cents: 100, cash_held_cents: 0} =
             Reservations.ledger()
  end

  test "transferred cash settles at destination and chargeback reclassifies all groups", %{
    conn: conn
  } do
    batch(conn, [
      opening("s", [2000], %{"rate_plan" => "advance_purchase"}),
      opening("refund"),
      opening("retain", [100], %{"rate_plan" => "advance_purchase"}),
      opening("convert"),
      pay("pay", "s", 400),
      transfer("t1", "s", "refund", 100),
      transfer("t2", "s", "retain", 100),
      transfer("t3", "s", "convert", 100)
    ])

    assert [
             %{"refunded_cents" => 100},
             %{"retained_cents" => 100},
             %{"credit_issued_cents" => 110}
           ] =
             batch(conn, [
               cancel("refund-c", "refund"),
               cancel("retain-c", "retain"),
               cancel("convert-c", "convert", %{"refund_method" => "hotel_credit"})
             ])

    assert [%{"charged_back_cents" => 400, "revision" => 6}] =
             batch(conn, [correct("charge", "charge_back_payment", %{"expected_revision" => 5})])

    for id <- ~w(refund retain convert), do: assert(Reservations.get_group(id).revision == 4)

    assert %{
             cash_held_cents: 0,
             cash_refunded_cents: 0,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             cash_charged_back_cents: 400,
             credit_liability_cents: 0
           } = Reservations.ledger(~D[2027-01-02])

    assert statement(conn, "pay")["held_by_group"] == []
  end

  test "cancelled original group remains the guarded group for reductions elsewhere", %{
    conn: conn
  } do
    batch(conn, [
      opening("s"),
      opening("d"),
      pay("pay", "s", 100),
      transfer("move", "s", "d", 100),
      cancel("cancel", "s")
    ])

    assert [
             %{"code" => "stale_revision", "group_id" => "s", "actual_revision" => 4},
             %{"revision" => 5, "outstanding_deposit_cents" => 0}
           ] =
             batch(conn, [
               correct("stale", "reduce_cash_payment", %{
                 "amount_cents" => 50,
                 "expected_revision" => 2
               }),
               correct("reduce", "reduce_cash_payment", %{
                 "amount_cents" => 50,
                 "expected_revision" => 4
               })
             ])

    assert Reservations.get_group("d").revision == 3
    assert statement(conn, "pay")["held_cents"] == 50
  end

  test "transferred credit keeps expiry paused and restores original lots without a bonus", %{
    conn: conn
  } do
    credit_source(conn)

    batch(conn, [
      opening("s"),
      opening("d"),
      op("redeem", "apply_hotel_credit", %{"group_id" => "s", "amount_cents" => 220})
    ])

    before = Reservations.ledger(~D[2028-02-01])

    assert [%{"status" => "applied"}] =
             batch(conn, [transfer("move", "s", "d", 220, %{"occurred_on" => "2028-02-01"})])

    assert Reservations.ledger(~D[2028-02-01]) == before

    assert [%{"refunded_cents" => 0, "credit_issued_cents" => 0}] =
             batch(conn, [
               cancel("return", "d", %{
                 "occurred_on" => "2028-02-01",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert Reservations.ledger(~D[2028-02-01]).credit_liability_cents == 0
    assert Repo.get_by!(CreditLot, source_operation_id: "lot").remaining_cents == 0
  end

  test "transferred shortfalled credit is absorbed on restoration and consumed normally", %{
    conn: conn
  } do
    credit_source(conn)

    batch(conn, [
      opening("s"),
      opening("d"),
      op("redeem", "apply_hotel_credit", %{"group_id" => "s", "amount_cents" => 220}),
      op("charge", "charge_back_payment", %{"payment_operation_id" => "issue-pay"}),
      transfer("move", "s", "d", 120)
    ])

    assert %{credit_liability_cents: 220, credit_shortfall_cents: 220} =
             Reservations.ledger(~D[2028-02-01])

    batch(conn, [cancel("return", "d", %{"occurred_on" => "2028-02-01"})])
    assert Repo.get_by!(CreditLot, source_operation_id: "lot").unrecovered_clawback_cents == 100

    assert %{credit_liability_cents: 100, credit_shortfall_cents: 100} =
             Reservations.ledger(~D[2028-02-01])

    batch(conn, [cancel("consume", "s", %{"occurred_on" => "2029-05-31"})])

    assert %{credit_liability_cents: 0, credit_shortfall_cents: 0} =
             Reservations.ledger(~D[2028-02-01])
  end

  test "transfers skip cancelled rooms and settlement bonuses use transferred funding order", %{
    conn: conn
  } do
    batch(conn, [
      opening("s", [25, 25]),
      opening("d", [25, 25, 25]),
      pay("first", "s", 5),
      pay("second", "s", 5),
      op("room-cancel", "cancel_rooms", %{"group_id" => "d", "room_ids" => ["r0"]}),
      transfer("move", "s", "d", 10)
    ])

    assert funding("d") == [{0, 0}, {5, 0}, {5, 0}]

    assert [%{"credit_issued_cents" => 11}] =
             batch(conn, [cancel("issue", "d", %{"refund_method" => "hotel_credit"})])

    # The second payment arrived at the destination first and receives the rounding cent.
    batch(conn, [
      op("charge-second", "charge_back_payment", %{"payment_operation_id" => "second"})
    ])

    assert Reservations.guest_credit("guest", ~D[2027-01-02]).available_cents == 5
    batch(conn, [op("charge-first", "charge_back_payment", %{"payment_operation_id" => "first"})])
    assert Reservations.guest_credit("guest", ~D[2027-01-02]).available_cents == 0
    assert statement(conn, "first")["held_by_group"] == []
    assert statement(conn, "second")["held_by_group"] == []
  end

  test "unexpired transferred credit restores its original lot and expiry", %{conn: conn} do
    credit_source(conn)
    original = Repo.get_by!(CreditLot, source_operation_id: "lot")

    batch(conn, [
      opening("s"),
      opening("d"),
      op("redeem", "apply_hotel_credit", %{"group_id" => "s", "amount_cents" => 220}),
      transfer("move", "s", "d", 220),
      cancel("restore", "d", %{"refund_method" => "hotel_credit"})
    ])

    assert Repo.all(CreditLot) == [original]

    assert %{credit_liability_cents: 220, cash_converted_to_credit_cents: 200} =
             Reservations.ledger(~D[2027-01-02])
  end
end
