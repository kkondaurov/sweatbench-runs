defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{
    CashAllocation,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    Operation,
    Repo,
    Reservations
  }

  defp opening(id, rates \\ [500, 500, 500], changes \\ %{}) do
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
      changes
    )
  end

  defp op(id, type, fields) do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => "2027-01-02"}, fields)
  end

  defp pay(id, group, amount),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount})

  defp cancel(id, group, rooms, fields \\ %{}),
    do: op(id, "cancel_rooms", Map.merge(%{"group_id" => group, "room_ids" => rooms}, fields))

  defp correct(id, type, payment, fields \\ %{}),
    do: op(id, type, Map.put(fields, "payment_operation_id", payment))

  defp batch(conn, ops),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp statement(conn, id) do
    data = conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

    assert Map.keys(data) |> Enum.sort() ==
             Enum.sort(
               ~w(payment_operation_id original_group_id recorded_cents held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
             )

    assert data["recorded_cents"] ==
             Enum.sum(
               for {key, value} <- data,
                   key not in ~w(payment_operation_id original_group_id recorded_cents),
                   do: value
             )

    data
  end

  defp snapshot,
    do:
      Enum.map(
        [Group, CashAllocation, CreditAllocation, CreditLot, CreditEntitlement],
        &Repo.all/1
      )

  defp room_cash(group),
    do: Enum.map(Reservations.get_group(group).rooms, & &1["cash_paid_cents"])

  test "reductions remove only their payment in reverse fill order and retries keep original results",
       %{conn: conn} do
    payment = pay("pay", "g", 150)
    [_, original, _] = batch(conn, [opening("g"), payment, pay("other", "g", 70)])
    assert room_cash("g") == [100, 100, 20]

    reduction =
      correct("reduce", "reduce_cash_payment", "pay", %{
        "amount_cents" => 60,
        "expected_revision" => 3
      })

    assert [result] = batch(conn, [reduction])

    assert result == %{
             "operation_id" => "reduce",
             "status" => "applied",
             "payment_operation_id" => "pay",
             "group_id" => "g",
             "amount_cents" => 60,
             "outstanding_deposit_cents" => 140,
             "revision" => 4
           }

    assert room_cash("g") == [90, 50, 20]
    assert statement(conn, "pay")["reduced_cents"] == 60
    assert statement(conn, "other")["held_cents"] == 70
    before = snapshot()
    assert batch(conn, [payment, reduction]) == [original, result]
    assert snapshot() == before

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(reduction, "amount_cents", 1)])

    assert [%{"amount_cents" => 90}] =
             batch(conn, [correct("rest", "reduce_cash_payment", "pay", %{"amount_cents" => 90})])

    assert statement(conn, "pay")["held_cents"] == 0
    assert Reservations.ledger().cash_reduced_cents == 150

    assert [%{"code" => "payment_not_chargeable"}, %{"code" => "payment_not_reducible"}] =
             batch(conn, [
               correct("cb", "charge_back_payment", "pay"),
               correct("empty", "reduce_cash_payment", "pay", %{"amount_cents" => 1})
             ])
  end

  test "partial settlements preserve other rooms and chargeback reconciles every cash disposition",
       %{conn: conn} do
    batch(conn, [
      opening("g", List.duplicate(500, 5)),
      pay("pay", "g", 500),
      correct("reduce", "reduce_cash_payment", "pay", %{"amount_cents" => 50}),
      cancel("refund", "g", ["r0"]),
      cancel("retain", "g", ["r1"], %{"occurred_on" => "2027-05-03"}),
      cancel("convert", "g", ["r2"], %{"refund_method" => "hotel_credit"})
    ])

    assert statement(conn, "pay") == %{
             "payment_operation_id" => "pay",
             "original_group_id" => "g",
             "recorded_cents" => 500,
             "held_cents" => 150,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 100,
             "reduced_cents" => 50,
             "charged_back_cents" => 0
           }

    assert %{
             lodging_total_cents: 1000,
             deposit_due_cents: 200,
             deposit_paid_cents: 150,
             revision: 6
           } = Reservations.get_group("g")

    cb = correct("cb", "charge_back_payment", "pay", %{"expected_revision" => 6})

    assert [
             %{"charged_back_cents" => 450, "revision" => 7, "outstanding_deposit_cents" => 200} =
               result
           ] = batch(conn, [cb])

    assert Reservations.ledger(~D[2027-01-02]) == %{
             cash_held_cents: 0,
             cash_refunded_cents: 0,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 50,
             cash_charged_back_cents: 450,
             credit_liability_cents: 0,
             credit_shortfall_cents: 0
           }

    assert statement(conn, "pay")["charged_back_cents"] == 450
    before = snapshot()
    assert batch(conn, [cb]) == [result]
    assert snapshot() == before

    assert [%{"code" => "payment_not_chargeable"}] =
             batch(conn, [Map.put(cb, "operation_id", "again") |> Map.delete("expected_revision")])

    assert [%{"refunded_cents" => 0, "revision" => 8}] =
             batch(conn, [op("full", "cancel_group", %{"group_id" => "g"})])

    assert Reservations.get_group("g").status == "cancelled"
  end

  test "combined bonuses telescope by funding order and clawbacks absorb restored fungible credit",
       %{conn: conn} do
    batch(conn, [
      opening("source", [25, 25]),
      pay("z-first", "source", 5),
      pay("a-second", "source", 5)
    ])

    assert [%{"cancelled_room_ids" => ["r0", "r1"], "credit_issued_cents" => 11}] =
             batch(conn, [
               cancel("issue", "source", ["r1", "r0"], %{"refund_method" => "hotel_credit"})
             ])

    batch(conn, [
      opening("target", [15, 25]),
      op("credit", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 8})
    ])

    target = Reservations.get_group("target")
    batch(conn, [correct("cb", "charge_back_payment", "a-second")])
    assert Reservations.get_group("target") == target

    assert %{credit_liability_cents: 8, credit_shortfall_cents: 2} =
             Reservations.ledger(~D[2027-01-02])

    assert Reservations.guest_credit("guest", ~D[2027-01-02]).available_cents == 0
    batch(conn, [cancel("restore", "target", ["r0"])])

    assert %{credit_liability_cents: 6, credit_shortfall_cents: 0} =
             Reservations.ledger(~D[2027-01-02])

    assert Reservations.guest_credit("guest", ~D[2027-01-02]).available_cents == 1
    batch(conn, [correct("cb-first", "charge_back_payment", "z-first")])

    assert %{credit_liability_cents: 5, credit_shortfall_cents: 5} =
             Reservations.ledger(~D[2027-01-02])

    batch(conn, [cancel("consume", "target", ["r1"], %{"occurred_on" => "2027-05-03"})])

    assert %{credit_liability_cents: 0, credit_shortfall_cents: 0} =
             Reservations.ledger(~D[2027-01-02])
  end

  test "credit allocations mix with cash in processing order and restore only selected lots", %{
    conn: conn
  } do
    batch(conn, [
      opening("source"),
      pay("source-pay", "source", 200),
      op("issue", "cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      opening("g"),
      pay("cash1", "g", 50),
      op("redeem", "apply_hotel_credit", %{"group_id" => "g", "amount_cents" => 120}),
      pay("cash2", "g", 100)
    ])

    group = Reservations.get_group("g")

    assert Enum.map(group.rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {50, 50},
             {30, 70},
             {70, 0}
           ]

    assert [%{"refunded_cents" => 30}] = batch(conn, [cancel("partial", "g", ["r1"])])
    assert Reservations.guest_credit("guest", ~D[2027-01-02]).available_cents == 170
    assert Reservations.ledger(~D[2027-01-02]).credit_liability_cents == 220
    assert statement(conn, "cash2")["held_cents"] == 70
    assert Enum.at(Reservations.get_group("g").rooms, 0) == Enum.at(group.rooms, 0)
    assert Enum.at(Reservations.get_group("g").rooms, 2) == Enum.at(group.rooms, 2)

    batch(conn, [
      op("rest", "cancel_group", %{"group_id" => "g", "refund_method" => "hotel_credit"})
    ])

    assert Reservations.guest_credit("guest", ~D[2027-01-02]).available_cents == 352
    assert Reservations.get_group("g").lodging_total_cents == 0
  end

  test "one payment contributes independent entitlements to multiple lots", %{conn: conn} do
    batch(conn, [
      opening("g", [25, 25]),
      pay("pay", "g", 10),
      cancel("lot1", "g", ["r0"], %{"refund_method" => "hotel_credit"}),
      cancel("lot2", "g", ["r1"], %{"refund_method" => "hotel_credit"})
    ])

    assert Reservations.guest_credit("guest", ~D[2027-01-02]).available_cents == 12
    batch(conn, [correct("cb", "charge_back_payment", "pay")])
    assert Reservations.guest_credit("guest", ~D[2027-01-02]).available_cents == 0
    assert statement(conn, "pay")["charged_back_cents"] == 10
  end

  test "expired restorations extinguish clawback before expiry and never resurrect liability", %{
    conn: conn
  } do
    batch(conn, [
      opening("source"),
      pay("pay", "source", 100),
      op("issue", "cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      opening("target", [500, 500], %{
        "arrival_on" => "2029-06-01",
        "departure_on" => "2029-06-02"
      }),
      op("redeem", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110}),
      correct("cb", "charge_back_payment", "pay")
    ])

    assert Reservations.ledger(~D[2028-02-01]).credit_shortfall_cents == 110
    batch(conn, [cancel("restore", "target", ["r0"], %{"occurred_on" => "2028-02-01"})])
    assert Repo.get_by!(CreditLot, source_operation_id: "issue").unrecovered_clawback_cents == 10

    assert %{credit_liability_cents: 10, credit_shortfall_cents: 10} =
             Reservations.ledger(~D[2028-02-01])

    assert Reservations.guest_credit("guest", ~D[2027-01-02]).available_cents == 0
  end

  test "validation, derived revisions, audit retention, and payment read errors", %{conn: conn} do
    batch(conn, [opening("g"), pay("pay", "g", 100), pay("rejected", "g", 999)])

    for type <- ~w(reduce_cash_payment charge_back_payment) do
      code =
        if type == "reduce_cash_payment",
          do: "payment_not_reducible",
          else: "payment_not_chargeable"

      for {target, expected} <- [
            {"missing", "operation_not_found"},
            {"open-g", code},
            {"rejected", code}
          ] do
        assert [%{"code" => ^expected}] =
                 batch(conn, [correct("#{type}-#{target}", type, target, %{"amount_cents" => 1})])
      end

      assert [%{"code" => "stale_revision", "actual_revision" => 2, "group_id" => "g"}] =
               batch(conn, [
                 correct("stale-#{type}", type, "pay", %{
                   "expected_revision" => 1,
                   "amount_cents" => -1
                 })
               ])
    end

    for amount <- [0, -1, "1", 1.5, nil] do
      assert [%{"code" => "invalid_amount"}] =
               batch(conn, [
                 correct("bad-#{inspect(amount)}", "reduce_cash_payment", "pay", %{
                   "amount_cents" => amount
                 })
               ])
    end

    assert [%{"code" => "reduction_exceeds_held_cash"}] =
             batch(conn, [
               correct("excess", "reduce_cash_payment", "pay", %{"amount_cents" => 101})
             ])

    for rooms <- [[], ["r0", "r0"], ["absent"], ["r0", "absent"], nil, "r0"] do
      before = snapshot()

      assert [%{"code" => "invalid_rooms"}] =
               batch(conn, [cancel("bad-rooms-#{inspect(rooms)}", "g", rooms)])

      assert snapshot() == before
    end

    assert [%{"code" => "refund_method_not_available"}] =
             batch(conn, [
               cancel("late", "g", ["r0"], %{
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2027-05-03"
               })
             ])

    assert conn |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    for id <- ["open-g", "rejected"] do
      assert conn |> get("/api/v1/payments/#{id}") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end

    before = snapshot()
    statement(conn, "pay")
    assert snapshot() == before
    batch(conn, [cancel("cancelled", "g", ["r0"])])
    assert [%{"code" => "invalid_rooms"}] = batch(conn, [cancel("again", "g", ["r0"])])

    assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
             batch(conn, [cancel("stale-room", "g", ["bad"], %{"expected_revision" => 2})])

    assert Repo.get_by!(Operation, operation_id: "excess").result["code"] ==
             "reduction_exceeds_held_cash"

    assert [%{"code" => "reduction_exceeds_held_cash"}] =
             batch(conn, [
               correct("excess", "reduce_cash_payment", "pay", %{"amount_cents" => 101})
             ])
  end

  test "shortfall is capped by active credit after prior non-refundable consumption", %{
    conn: conn
  } do
    batch(conn, [
      opening("source"),
      pay("pay", "source", 100),
      op("issue", "cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      opening("target", [150, 400]),
      op("redeem", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110}),
      cancel("consume", "target", ["r0"], %{"occurred_on" => "2027-05-03"}),
      correct("cb", "charge_back_payment", "pay")
    ])

    assert %{credit_liability_cents: 80, credit_shortfall_cents: 80} =
             Reservations.ledger(~D[2027-01-02])

    assert Repo.get_by!(CreditLot, source_operation_id: "issue").unrecovered_clawback_cents == 110
    batch(conn, [cancel("restore", "target", ["r1"])])

    assert %{credit_liability_cents: 0, credit_shortfall_cents: 0} =
             Reservations.ledger(~D[2027-01-02])

    assert Repo.get_by!(CreditLot, source_operation_id: "issue").unrecovered_clawback_cents == 30
    assert Reservations.guest_credit("guest", ~D[2027-01-02]).available_cents == 0
  end

  test "credit stays fungible across multiple recipient groups and chargeback order", %{
    conn: conn
  } do
    for {suffix, first, second} <- [{"a", "pay1", "pay2"}, {"b", "pay2", "pay1"}] do
      source = "source-#{suffix}"

      batch(conn, [
        opening(source, [50]),
        pay("pay1-#{suffix}", source, 5),
        pay("pay2-#{suffix}", source, 5),
        op("issue-#{suffix}", "cancel_group", %{
          "group_id" => source,
          "refund_method" => "hotel_credit"
        }),
        opening("target1-#{suffix}", [15]),
        opening("target2-#{suffix}", [20]),
        op("redeem1-#{suffix}", "apply_hotel_credit", %{
          "group_id" => "target1-#{suffix}",
          "amount_cents" => 3
        }),
        op("redeem2-#{suffix}", "apply_hotel_credit", %{
          "group_id" => "target2-#{suffix}",
          "amount_cents" => 4
        }),
        correct("cb1-#{suffix}", "charge_back_payment", "#{first}-#{suffix}"),
        correct("cb2-#{suffix}", "charge_back_payment", "#{second}-#{suffix}")
      ])

      assert Reservations.guest_credit("guest", ~D[2027-01-02]).available_cents == 0

      assert %{credit_liability_cents: 7, credit_shortfall_cents: 7} =
               Reservations.ledger(~D[2027-01-02])

      assert Reservations.get_group("target1-#{suffix}").revision == 2
      assert Reservations.get_group("target2-#{suffix}").revision == 2

      batch(conn, [
        cancel("return1-#{suffix}", "target1-#{suffix}", ["r0"]),
        cancel("return2-#{suffix}", "target2-#{suffix}", ["r0"])
      ])

      assert %{credit_liability_cents: 0, credit_shortfall_cents: 0} =
               Reservations.ledger(~D[2027-01-02])
    end
  end
end
