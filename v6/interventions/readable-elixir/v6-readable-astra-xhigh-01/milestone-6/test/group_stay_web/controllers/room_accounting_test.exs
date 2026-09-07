defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerFixtures

  alias GroupStay.Repo
  alias GroupStay.Credits.{Allocation, Entitlement, Lot}
  alias GroupStay.Finance.{CashAllocation, CashEntry}
  alias GroupStay.Reservations.{Group, Room}

  test "mixed funding fills rooms in processing order and selected settlement leaves other rooms untouched",
       %{conn: conn} do
    apply_all(conn, [
      booking("source", [100]),
      cash("source", "source-payment", 100),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      booking("main", [100, 100, 100]),
      cash("main", "first", 80, %{"occurred_on" => "2026-11-01"}),
      operation("apply_hotel_credit", %{"group_id" => "main", "amount_cents" => 90}),
      cash("main", "second", 100, %{"occurred_on" => "2026-09-01"})
    ])

    assert room_balances(conn, "main") == [
             {"r-0", "active", 80, 20},
             {"r-1", "active", 30, 70},
             {"r-2", "active", 70, 0}
           ]

    remaining_room = Enum.at(group(conn, "main")["rooms"], 1)

    cancellation =
      operation("cancel_rooms", %{
        "group_id" => "main",
        "room_ids" => ["r-2", "r-0"],
        "expected_revision" => 4
      })

    assert [
             %{
               "cancelled_room_ids" => ["r-0", "r-2"],
               "refunded_cents" => 150,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 5
             }
           ] = submit(conn, [cancellation])

    assert Enum.at(group(conn, "main")["rooms"], 1) == remaining_room

    assert %{
             "status" => "active",
             "lodging_total_cents" => 500,
             "deposit_due_cents" => 100,
             "cash_paid_cents" => 30,
             "credit_paid_cents" => 70,
             "outstanding_deposit_cents" => 0
           } = group(conn, "main")

    assert room_balances(conn, "main") == [
             {"r-0", "cancelled", 0, 0},
             {"r-1", "active", 30, 70},
             {"r-2", "cancelled", 0, 0}
           ]

    assert credit(conn)["available_cents"] == 40

    assert [%{"refunded_cents" => 30, "revision" => 6}] =
             submit(conn, [operation("cancel_group", %{"group_id" => "main"})])

    assert %{
             "status" => "cancelled",
             "lodging_total_cents" => 0,
             "deposit_due_cents" => 0,
             "deposit_paid_cents" => 0
           } = group(conn, "main")

    assert credit(conn)["available_cents"] == 110
    assert ledger(conn)["cash_refunded_cents"] == 180
    assert_statement(conn, "first", "main", 80, refunded_cents: 80)
    assert_statement(conn, "second", "main", 100, refunded_cents: 100)
  end

  test "partial cancellations round combined cash once and can issue several lots from a group",
       %{conn: conn} do
    apply_all(conn, [booking("main", [3, 2, 5]), cash("main", "payment", 10)])

    first =
      operation("cancel_rooms", %{
        "group_id" => "main",
        "room_ids" => ["r-1", "r-0"],
        "refund_method" => "hotel_credit"
      })

    last =
      operation("cancel_rooms", %{
        "group_id" => "main",
        "room_ids" => ["r-2"],
        "refund_method" => "hotel_credit"
      })

    assert [
             %{"credit_issued_cents" => 6, "revision" => 3} = one,
             %{"credit_issued_cents" => 6, "revision" => 4} = two
           ] = submit(conn, [first, last])

    assert group(conn, "main")["status"] == "cancelled"
    assert credit(conn)["available_cents"] == 12
    assert length(credit(conn)["lots"]) == 2
    assert_statement(conn, "payment", "main", 10, converted_to_credit_cents: 10)
    before = snapshot()
    assert submit(conn, [first, last]) == [one, two]
    assert snapshot() == before

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [Map.put(first, "room_ids", ["r-0", "r-1"])])

    assert [%{"charged_back_cents" => 10, "revision" => 5}] =
             submit(conn, [correction("charge_back_payment", "payment")])

    assert credit(conn)["available_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
    assert_statement(conn, "payment", "main", 10, charged_back_cents: 10)
  end

  test "reductions remove only the target's held cash in reverse fill order and compose with refills",
       %{conn: conn} do
    original = cash("main", "payment", 250)

    [_, original_result, _] =
      apply_all(conn, [booking("main", [100, 100, 100]), original, cash("main", "later", 50)])

    reduction =
      correction("reduce_cash_payment", "payment", %{
        "amount_cents" => 75,
        "expected_revision" => 3
      })

    assert [
             %{
               "payment_operation_id" => "payment",
               "group_id" => "main",
               "amount_cents" => 75,
               "outstanding_deposit_cents" => 75,
               "revision" => 4
             } = result
           ] = submit(conn, [reduction])

    assert room_balances(conn, "main") == [
             {"r-0", "active", 100, 0},
             {"r-1", "active", 75, 0},
             {"r-2", "active", 50, 0}
           ]

    apply_all(conn, [cash("main", "refill", 60)])

    assert room_balances(conn, "main") == [
             {"r-0", "active", 100, 0},
             {"r-1", "active", 100, 0},
             {"r-2", "active", 85, 0}
           ]

    apply_all(conn, [operation("cancel_rooms", %{"group_id" => "main", "room_ids" => ["r-1"]})])

    assert_statement(conn, "payment", "main", 250,
      held_cents: 100,
      refunded_cents: 75,
      reduced_cents: 75
    )

    apply_all(conn, [correction("reduce_cash_payment", "payment", %{"amount_cents" => 100})])
    assert_statement(conn, "payment", "main", 250, refunded_cents: 75, reduced_cents: 175)
    assert_statement(conn, "later", "main", 50, held_cents: 50)
    assert_statement(conn, "refill", "main", 60, held_cents: 35, refunded_cents: 25)
    assert group(conn, "main")["outstanding_deposit_cents"] == 115
    assert ledger(conn)["cash_reduced_cents"] == 175
    before = snapshot()
    assert submit(conn, [original, reduction]) == [original_result, result]
    assert snapshot() == before

    assert [%{"code" => "payment_not_reducible"}] =
             submit(conn, [correction("reduce_cash_payment", "payment", %{"amount_cents" => 1})])
  end

  test "room selection is atomic, revisions precede domain validation, and all-room cancellation closes a group",
       %{conn: conn} do
    apply_all(conn, [
      booking("main", [100, 0]),
      cash("main", "payment", 50),
      booking("other", [100])
    ])

    for ids <- [nil, [], "r-0", [nil], ["unknown"], ["r-0", "r-0"], ["r-0", "unknown"]] do
      before = snapshot()

      assert [%{"code" => "invalid_rooms"}] =
               submit(conn, [
                 operation("cancel_rooms", %{"group_id" => "main", "room_ids" => ids})
               ])

      assert snapshot() == before
    end

    before = snapshot()

    assert [
             %{"code" => "stale_revision", "actual_revision" => 2},
             %{"code" => "group_not_found"},
             %{"code" => "refund_method_not_available"}
           ] =
             submit(conn, [
               operation("cancel_rooms", %{
                 "group_id" => "main",
                 "expected_revision" => 1,
                 "room_ids" => nil,
                 "refund_method" => "unknown"
               }),
               operation("cancel_rooms", %{"group_id" => "missing", "expected_revision" => 9}),
               operation("cancel_rooms", %{
                 "group_id" => "main",
                 "room_ids" => ["r-0"],
                 "occurred_on" => "2026-12-01",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert snapshot() == before

    assert [%{"revision" => 3, "refunded_cents" => 0}] =
             submit(conn, [
               operation("cancel_rooms", %{"group_id" => "main", "room_ids" => ["r-1"]})
             ])

    assert group(conn, "main")["status"] == "active"

    assert [
             %{"code" => "invalid_rooms"},
             %{"cancelled_room_ids" => ["r-0"], "revision" => 4},
             %{"code" => "group_not_active"}
           ] =
             submit(conn, [
               operation("cancel_rooms", %{"group_id" => "main", "room_ids" => ["r-0", "r-1"]}),
               operation("cancel_rooms", %{"group_id" => "main", "room_ids" => ["r-0"]}),
               operation("cancel_group", %{"group_id" => "main"})
             ])
  end

  test "correction validation distinguishes missing, ineligible, invalid amounts, and exhausted payments",
       %{conn: conn} do
    rejected = cash("missing", "rejected", 10)
    submit(conn, [rejected])
    apply_all(conn, [booking("main", [100]), cash("main", "payment", 50)])

    for type <- ["reduce_cash_payment", "charge_back_payment"] do
      code =
        if type == "reduce_cash_payment",
          do: "payment_not_reducible",
          else: "payment_not_chargeable"

      before = snapshot()

      assert [
               %{"code" => "operation_not_found"},
               %{"code" => ^code},
               %{"code" => ^code},
               %{"code" => "stale_revision", "group_id" => "main", "actual_revision" => 2}
             ] =
               submit(conn, [
                 correction(type, "unknown", %{"amount_cents" => -1}),
                 correction(type, "open-main", %{"amount_cents" => 1}),
                 correction(type, "rejected", %{"amount_cents" => 1}),
                 correction(type, "payment", %{
                   "amount_cents" => -1,
                   "expected_revision" => 1,
                   "occurred_on" => "bad"
                 })
               ])

      assert snapshot() == before
    end

    for amount <- [0, -1, 1.5, "10", nil] do
      assert [%{"code" => "invalid_amount"}] =
               submit(conn, [
                 correction("reduce_cash_payment", "payment", %{"amount_cents" => amount})
               ])
    end

    assert [%{"code" => "invalid_operation"}, %{"code" => "reduction_exceeds_held_cash"}] =
             submit(conn, [
               correction("reduce_cash_payment", "payment"),
               correction("reduce_cash_payment", "payment", %{"amount_cents" => 51})
             ])

    apply_all(conn, [correction("reduce_cash_payment", "payment", %{"amount_cents" => 50})])

    assert [
             %{"code" => "stale_revision"},
             %{"code" => "payment_not_reducible"},
             %{"code" => "payment_not_chargeable"}
           ] =
             submit(conn, [
               correction("charge_back_payment", "payment", %{"expected_revision" => 2}),
               correction("reduce_cash_payment", "payment", %{"amount_cents" => 0}),
               correction("charge_back_payment", "payment")
             ])

    assert_statement(conn, "payment", "main", 50, reduced_cents: 50)
  end

  test "a chargeback reclassifies held, refunded, retained, and converted cash while preserving reductions",
       %{conn: conn} do
    payment = cash("main", "payment", 400)
    [_, paid] = apply_all(conn, [booking("main", [100, 100, 100, 100]), payment])

    apply_all(conn, [
      correction("reduce_cash_payment", "payment", %{"amount_cents" => 50}),
      operation("cancel_rooms", %{"group_id" => "main", "room_ids" => ["r-0"]}),
      operation("cancel_rooms", %{
        "group_id" => "main",
        "room_ids" => ["r-1"],
        "occurred_on" => "2026-12-01"
      }),
      operation("cancel_rooms", %{
        "group_id" => "main",
        "room_ids" => ["r-2"],
        "refund_method" => "hotel_credit"
      }),
      booking("recipient", [100]),
      operation("apply_hotel_credit", %{"group_id" => "recipient", "amount_cents" => 80})
    ])

    assert_statement(conn, "payment", "main", 400,
      held_cents: 50,
      refunded_cents: 100,
      retained_cents: 100,
      converted_to_credit_cents: 100,
      reduced_cents: 50
    )

    recipient = group(conn, "recipient")

    chargeback =
      correction("charge_back_payment", "payment", %{
        "expected_revision" => 6,
        "group_id" => "ignored"
      })

    assert [
             %{
               "payment_operation_id" => "payment",
               "group_id" => "main",
               "charged_back_cents" => 350,
               "outstanding_deposit_cents" => 100,
               "revision" => 7
             } = charged
           ] = submit(conn, [chargeback])

    assert group(conn, "recipient") == recipient
    assert_statement(conn, "payment", "main", 400, reduced_cents: 50, charged_back_cents: 350)

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 50,
             "cash_charged_back_cents" => 350,
             "credit_liability_cents" => 80,
             "credit_shortfall_cents" => 80
           }

    assert credit(conn)["available_cents"] == 0
    before = snapshot()
    assert submit(conn, [chargeback, payment]) == [charged, paid]
    assert snapshot() == before

    assert [%{"code" => "payment_not_chargeable"}, %{"code" => "payment_not_reducible"}] =
             submit(conn, [
               correction("charge_back_payment", "payment"),
               correction("reduce_cash_payment", "payment", %{"amount_cents" => 1})
             ])

    apply_all(conn, [operation("cancel_group", %{"group_id" => "recipient"})])
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
    assert credit(conn)["available_cents"] == 0
    assert group(conn, "main")["revision"] == 7
  end

  test "entitlements telescope at half cents and spent lot credit stays fungible across chargebacks",
       %{conn: conn} do
    apply_all(conn, [
      booking("main", [5]),
      cash("main", "first", 4),
      cash("main", "second", 1),
      operation("cancel_group", %{"group_id" => "main", "refund_method" => "hotel_credit"}),
      booking("recipient", [10]),
      operation("apply_hotel_credit", %{"group_id" => "recipient", "amount_cents" => 5})
    ])

    assert credit(conn)["available_cents"] == 1
    # The first payment created 4 cents; the second owns 2, including the rounding cent.
    apply_all(conn, [correction("charge_back_payment", "first")])
    assert ledger(conn)["credit_shortfall_cents"] == 3
    assert ledger(conn)["credit_liability_cents"] == 5
    assert credit(conn)["available_cents"] == 0
    apply_all(conn, [correction("charge_back_payment", "second")])
    assert ledger(conn)["credit_shortfall_cents"] == 5
    assert ledger(conn)["credit_liability_cents"] == 5
    apply_all(conn, [operation("cancel_group", %{"group_id" => "recipient"})])
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  for {on, available} <- [{"2026-10-03", 7}, {"2027-10-04", 0}] do
    test "restoration on #{on} absorbs shortfall before making excess available or expiring it",
         %{conn: conn} do
      apply_all(conn, [
        booking("main", [10]),
        cash("main", "first", 4),
        cash("main", "second", 6),
        operation("cancel_group", %{"group_id" => "main", "refund_method" => "hotel_credit"}),
        booking("recipient", [8], %{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-02"}),
        operation("apply_hotel_credit", %{"group_id" => "recipient", "amount_cents" => 8}),
        correction("charge_back_payment", "first")
      ])

      assert ledger(conn)["credit_shortfall_cents"] == 1
      assert [%Lot{unrecovered_clawback_cents: 1, remaining_cents: 0}] = Repo.all(Lot)

      apply_all(conn, [
        operation("cancel_group", %{"group_id" => "recipient", "occurred_on" => unquote(on)})
      ])

      assert [%Lot{unrecovered_clawback_cents: 0, remaining_cents: unquote(available)}] =
               Repo.all(Lot)

      assert credit(conn, unquote(on))["available_cents"] == unquote(available)
      assert ledger(conn, unquote(on))["credit_liability_cents"] == unquote(available)
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert group(conn, "main")["revision"] == 5
    end
  end

  test "non-refundable credit settlement caps shortfall without creating credit availability", %{
    conn: conn
  } do
    apply_all(conn, [
      booking("main", [100]),
      cash("main", "payment", 100),
      operation("cancel_group", %{"group_id" => "main", "refund_method" => "hotel_credit"}),
      booking("recipient", [50, 60]),
      operation("apply_hotel_credit", %{"group_id" => "recipient", "amount_cents" => 110}),
      correction("charge_back_payment", "payment"),
      operation("cancel_rooms", %{
        "group_id" => "recipient",
        "room_ids" => ["r-0"],
        "occurred_on" => "2026-12-01"
      })
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 60
    assert ledger(conn)["credit_liability_cents"] == 60
    assert credit(conn)["available_cents"] == 0
    assert [%Lot{unrecovered_clawback_cents: 110}] = Repo.all(Lot)
    apply_all(conn, [operation("cancel_group", %{"group_id" => "recipient"})])
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
    assert [%Lot{unrecovered_clawback_cents: 50}] = Repo.all(Lot)
  end

  test "payment statements distinguish missing records and ineligible durable records and never write",
       %{conn: conn} do
    assert conn |> get(~p"/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    rejected = cash("missing", "rejected", 1)
    submit(conn, [rejected])
    apply_all(conn, [booking("main", [100]), cash("main", " Payment-É 17 ", 50)])
    before = snapshot()

    for id <- ["open-main", "rejected"] do
      assert conn |> recycle() |> get(~p"/api/v1/payments/#{id}") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end

    assert_statement(conn, " Payment-É 17 ", "main", 50, held_cents: 50)
    assert snapshot() == before
  end

  test "a missing-target rejection is remembered even after that payment is recorded", %{
    conn: conn
  } do
    reduction = correction("reduce_cash_payment", "payment", %{"amount_cents" => 10})
    assert [%{"code" => "operation_not_found"} = rejected] = submit(conn, [reduction])
    apply_all(conn, [booking("main", [100]), cash("main", "payment", 50)])
    before = snapshot()
    assert submit(conn, [reduction]) == [rejected]
    assert snapshot() == before

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [Map.put(reduction, "amount_cents", 20)])
  end

  test "shortfall is capped separately for each lot and excludes unrelated applied credit", %{
    conn: conn
  } do
    apply_all(conn, [
      booking("first", [100]),
      cash("first", "first-payment", 100),
      operation("cancel_group", %{
        "group_id" => "first",
        "refund_method" => "hotel_credit",
        "operation_id" => "a-lot"
      }),
      booking("consumed", [100]),
      operation("apply_hotel_credit", %{"group_id" => "consumed", "amount_cents" => 100}),
      operation("cancel_group", %{"group_id" => "consumed", "occurred_on" => "2026-12-01"}),
      booking("second", [100]),
      cash("second", "second-payment", 100),
      operation("cancel_group", %{
        "group_id" => "second",
        "refund_method" => "hotel_credit",
        "operation_id" => "z-lot"
      }),
      booking("recipient", [110]),
      operation("apply_hotel_credit", %{"group_id" => "recipient", "amount_cents" => 110}),
      correction("charge_back_payment", "first-payment")
    ])

    assert ledger(conn)["credit_liability_cents"] == 120
    assert ledger(conn)["credit_shortfall_cents"] == 10
    assert credit(conn)["available_cents"] == 10
    apply_all(conn, [operation("cancel_group", %{"group_id" => "recipient"})])
    assert ledger(conn)["credit_liability_cents"] == 110
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert credit(conn)["available_cents"] == 110
  end

  test "revoking expired unspent entitlement creates no shortfall or negative liability", %{
    conn: conn
  } do
    apply_all(conn, [
      booking("main", [100]),
      cash("main", "payment", 100),
      operation("cancel_group", %{"group_id" => "main", "refund_method" => "hotel_credit"})
    ])

    assert ledger(conn, "2027-10-04")["credit_liability_cents"] == 0

    apply_all(conn, [
      correction("charge_back_payment", "payment", %{"occurred_on" => "2027-10-04"})
    ])

    assert ledger(conn, "2027-10-04")["credit_liability_cents"] == 0
    assert ledger(conn, "2027-10-04")["credit_shortfall_cents"] == 0
    assert [%Lot{remaining_cents: 0, unrecovered_clawback_cents: 0}] = Repo.all(Lot)
    assert_statement(conn, "payment", "main", 100, charged_back_cents: 100)
  end

  test "repeated corrections keep lifetime totals exact beyond SQLite's integer range", %{
    conn: conn
  } do
    maximum = 9_223_372_036_854_775_807

    apply_all(conn, [
      booking("main", [0], %{
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "large", "nightly_rate_cents" => maximum}]
      })
    ])

    for number <- 1..2 do
      apply_all(conn, [
        cash("main", "reduce-#{number}", maximum),
        correction("reduce_cash_payment", "reduce-#{number}", %{"amount_cents" => maximum}),
        cash("main", "charge-#{number}", maximum),
        correction("charge_back_payment", "charge-#{number}")
      ])

      assert_statement(conn, "reduce-#{number}", "main", maximum, reduced_cents: maximum)
      assert_statement(conn, "charge-#{number}", "main", maximum, charged_back_cents: maximum)
    end

    assert ledger(conn)["cash_reduced_cents"] == maximum * 2
    assert ledger(conn)["cash_charged_back_cents"] == maximum * 2
    assert group(conn, "main")["outstanding_deposit_cents"] == maximum
  end

  defp booking(id, deposits, overrides \\ %{}) do
    open_group(%{
      "operation_id" => "open-#{id}",
      "group_id" => id,
      "departure_on" => "2026-12-11",
      "rooms" =>
        deposits
        |> Enum.with_index()
        |> Enum.map(fn {due, n} -> %{"room_id" => "r-#{n}", "nightly_rate_cents" => due * 5} end)
    })
    |> Map.merge(overrides)
  end

  defp cash(group_id, id, amount, overrides \\ %{}),
    do:
      operation(
        "record_cash_payment",
        Map.merge(
          %{"operation_id" => id, "group_id" => group_id, "amount_cents" => amount},
          overrides
        )
      )

  defp correction(type, payment_id, overrides \\ %{}),
    do:
      operation(type, %{"payment_operation_id" => payment_id})
      |> Map.delete("group_id")
      |> Map.merge(overrides)

  defp submit(conn, operations),
    do:
      conn
      |> recycle()
      |> post(~p"/api/v1/partner-batches", %{operations: operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp apply_all(conn, operations) do
    results = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp group(conn, id),
    do:
      conn
      |> recycle()
      |> get(~p"/api/v1/groups/#{id}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp ledger(conn, on \\ "2026-10-03"),
    do:
      conn
      |> recycle()
      |> get(~p"/api/v1/ledger?on=#{on}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp credit(conn, on \\ "2026-10-03"),
    do:
      conn
      |> recycle()
      |> get(~p"/api/v1/guests/guest-22/credit?on=#{on}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp room_balances(conn, id),
    do:
      Enum.map(
        group(conn, id)["rooms"],
        &{&1["room_id"], &1["status"], &1["cash_paid_cents"], &1["credit_paid_cents"]}
      )

  defp assert_statement(conn, id, group_id, recorded, dispositions) do
    fields =
      ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)

    amounts =
      Map.merge(
        Map.new(fields, &{&1, 0}),
        Map.new(dispositions, fn {key, value} -> {Atom.to_string(key), value} end)
      )

    expected =
      Map.merge(amounts, %{
        "payment_operation_id" => id,
        "original_group_id" => group_id,
        "recorded_cents" => recorded
      })

    assert conn |> recycle() |> get(~p"/api/v1/payments/#{id}") |> json_response(200) == %{
             "data" => expected
           }

    assert amounts |> Map.values() |> Enum.sum() == recorded
  end

  defp snapshot do
    for schema <- [Group, Room, CashEntry, CashAllocation, Lot, Allocation, Entitlement],
        into: %{},
        do: {schema, Repo.all(schema)}
  end
end
