defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures
  alias GroupStay.Repo
  alias GroupStay.Reservations

  alias GroupStay.Reservations.{
    CashAllocation,
    CashEntry,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    RoomCreditAllocation
  }

  test "cash and credit fill rooms in processing order, and partial settlement leaves other rooms unchanged",
       %{conn: conn} do
    seed_credit(conn, 100)

    submit(conn, [
      small_group(),
      payment(%{"amount_cents" => 60}),
      credit_application(%{"amount_cents" => 110}),
      payment(%{"amount_cents" => 130})
    ])

    before = group(conn)
    assert before["revision"] == 4

    assert Enum.map(before["rooms"], &Map.take(&1, ~w(room_id cash_paid_cents credit_paid_cents))) ==
             [
               %{"room_id" => "z", "cash_paid_cents" => 60, "credit_paid_cents" => 40},
               %{"room_id" => "a", "cash_paid_cents" => 30, "credit_paid_cents" => 70},
               %{"room_id" => "m", "cash_paid_cents" => 100, "credit_paid_cents" => 0}
             ]

    operation =
      room_cancellation(%{
        "room_ids" => ["m", "z"],
        "refund_method" => "hotel_credit",
        "expected_revision" => 4
      })

    assert [
             result = %{
               "cancelled_room_ids" => ["z", "m"],
               "credit_issued_cents" => 176,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "revision" => 5
             }
           ] = submit(conn, [operation])

    after_cancel = group(conn)
    assert Enum.at(after_cancel["rooms"], 1) == Enum.at(before["rooms"], 1)

    assert Map.take(
             after_cancel,
             ~w(status lodging_total_cents deposit_due_cents deposit_paid_cents outstanding_deposit_cents)
           ) == %{
             "status" => "active",
             "lodging_total_cents" => 500,
             "deposit_due_cents" => 100,
             "deposit_paid_cents" => 100,
             "outstanding_deposit_cents" => 0
           }

    assert Enum.map(after_cancel["rooms"], & &1["status"]) == ["cancelled", "active", "cancelled"]
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 216
    assert ledger(conn)["credit_liability_cents"] == 286

    snapshot = snapshot()
    assert submit(conn, [operation]) == [result]
    assert snapshot() == snapshot
    assert [%{"refunded_cents" => 30, "revision" => 6}] = submit(conn, [cancellation()])
    assert group(conn)["lodging_total_cents"] == 0
    assert group(conn)["status"] == "cancelled"
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 286
    assert ledger(conn)["cash_held_cents"] == 0
    assert ledger(conn)["cash_refunded_cents"] == 30
  end

  test "room prices round separately and combined cancellation cash receives one bonus", %{
    conn: conn
  } do
    submit(conn, [
      small_group(%{"rooms" => rooms([{"z", 25}, {"a", 25}, {"free", 0}])}),
      payment(%{"amount_cents" => 10})
    ])

    assert Enum.map(group(conn)["rooms"], & &1["deposit_due_cents"]) == [5, 5, 0]

    assert [%{"credit_issued_cents" => 11, "cancelled_room_ids" => ["z", "a"]}] =
             submit(conn, [
               room_cancellation(%{"room_ids" => ["a", "z"], "refund_method" => "hotel_credit"})
             ])

    assert group(conn)["status"] == "active"

    assert [%{"revision" => 4, "credit_issued_cents" => 0}] =
             submit(conn, [room_cancellation(%{"room_ids" => ["free"]})])

    assert group(conn)["status"] == "cancelled"
  end

  test "invalid room selections reject atomically and revision checks precede room and policy validation",
       %{conn: conn} do
    submit(conn, [
      small_group(),
      payment(%{"amount_cents" => 150}),
      room_cancellation(%{"room_ids" => ["z"]})
    ])

    for selection <- [[], nil, "a", ["a", "a"], ["a", "z"], ["a", "missing"], [1], [%{}]] do
      before = snapshot()

      assert [%{"code" => "invalid_rooms"}] =
               submit(conn, [room_cancellation(%{"room_ids" => selection})])

      assert snapshot() == before
    end

    assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
             submit(conn, [
               room_cancellation(%{
                 "room_ids" => [],
                 "expected_revision" => 1,
                 "refund_method" => "bad"
               })
             ])

    assert [%{"code" => "refund_method_not_available"}] =
             submit(conn, [
               room_cancellation(%{
                 "room_ids" => ["a"],
                 "occurred_on" => "2026-12-01",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert [%{"code" => "invalid_operation"}] =
             submit(conn, [room_cancellation(%{"room_ids" => ["a"], "refund_method" => "bad"})])

    assert [%{"code" => "group_not_found"}] =
             submit(conn, [
               room_cancellation(%{"group_id" => "missing", "expected_revision" => 1})
             ])

    assert group(conn)["revision"] == 3
  end

  test "reductions remove only the target payment's held cash in reverse fill order and allow refilling holes",
       %{conn: conn} do
    original = payment(%{"operation_id" => "payment", "amount_cents" => 180})

    [_, original_result, _] =
      submit(conn, [
        small_group(),
        original,
        payment(%{"operation_id" => "second", "amount_cents" => 90})
      ])

    assert [%{"revision" => 4, "outstanding_deposit_cents" => 80}] =
             submit(conn, [reduction(%{"expected_revision" => 3})])

    assert cash_by_room(conn) == [100, 50, 70]
    assert_statement(conn, "payment", %{recorded_cents: 180, held_cents: 130, reduced_cents: 50})
    assert_statement(conn, "second", %{recorded_cents: 90, held_cents: 90})

    submit(conn, [payment(%{"operation_id" => "fill", "amount_cents" => 60})])
    assert cash_by_room(conn) == [100, 100, 80]

    assert [%{"refunded_cents" => 100}] =
             submit(conn, [room_cancellation(%{"room_ids" => ["z"]})])

    assert_statement(conn, "payment", %{
      recorded_cents: 180,
      held_cents: 30,
      refunded_cents: 100,
      reduced_cents: 50
    })

    assert [%{"code" => "reduction_exceeds_held_cash"}] =
             submit(conn, [reduction(%{"amount_cents" => 31})])

    assert [%{"amount_cents" => 30, "outstanding_deposit_cents" => 50}] =
             submit(conn, [reduction(%{"amount_cents" => 30})])

    assert [%{"code" => "payment_not_reducible"}] =
             submit(conn, [reduction(%{"amount_cents" => 1})])

    assert_statement(conn, "payment", %{
      recorded_cents: 180,
      refunded_cents: 100,
      reduced_cents: 80
    })

    assert ledger(conn)["cash_reduced_cents"] == 80
    assert ledger(conn)["cash_held_cents"] == 150
    before = snapshot()
    assert submit(conn, [original]) == [original_result]
    assert snapshot() == before
  end

  test "payment-targeted validation distinguishes missing, unusable, invalid amount, and stale targets",
       %{conn: conn} do
    submit(conn, [
      small_group(%{"operation_id" => "opening"}),
      payment(%{"operation_id" => "rejected", "amount_cents" => 999}),
      payment(%{"operation_id" => "payment", "amount_cents" => 50})
    ])

    for operation <- [
          reduction(%{"payment_operation_id" => "absent"}),
          chargeback(%{"payment_operation_id" => "absent"})
        ] do
      assert [%{"code" => "operation_not_found"}] = submit(conn, [operation])
    end

    for id <- ["opening", "rejected"] do
      assert [%{"code" => "payment_not_reducible"}] =
               submit(conn, [reduction(%{"payment_operation_id" => id})])

      assert [%{"code" => "payment_not_chargeable"}] =
               submit(conn, [chargeback(%{"payment_operation_id" => id})])

      assert conn |> get("/api/v1/payments/#{id}") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end

    assert conn |> get("/api/v1/payments/absent") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    for amount <- [0, -1, 1.0, "1", nil, true, %{}] do
      assert [%{"code" => "invalid_amount"}] =
               submit(conn, [reduction(%{"amount_cents" => amount})])
    end

    assert [%{"code" => "stale_revision", "group_id" => "group-81", "actual_revision" => 2}] =
             submit(conn, [reduction(%{"expected_revision" => 1, "amount_cents" => -1})])

    assert [%{"revision" => 3}] = submit(conn, [reduction(%{"amount_cents" => 50})])
    assert [%{"code" => "payment_not_chargeable"}] = submit(conn, [chargeback()])

    assert [%{"code" => "payment_not_reducible"}] =
             submit(conn, [reduction(%{"amount_cents" => 0})])

    assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
             submit(conn, [chargeback(%{"expected_revision" => 2})])
  end

  test "chargeback reclassifies held, refunded, retained, and converted cash while preserving reductions",
       %{conn: conn} do
    original = payment(%{"operation_id" => "payment", "amount_cents" => 300})

    [_, original_result] =
      submit(conn, [
        small_group(%{"rooms" => rooms([{"z", 500}, {"a", 500}, {"m", 500}, {"last", 500}])}),
        original
      ])

    submit(conn, [
      reduction(%{"amount_cents" => 10}),
      room_cancellation(%{"room_ids" => ["z"]}),
      room_cancellation(%{"room_ids" => ["a"], "occurred_on" => "2026-12-01"}),
      room_cancellation(%{"room_ids" => ["m"], "refund_method" => "hotel_credit"})
    ])

    assert_statement(conn, "payment", %{
      recorded_cents: 300,
      refunded_cents: 100,
      retained_cents: 100,
      converted_to_credit_cents: 90,
      reduced_cents: 10
    })

    operation = chargeback(%{"expected_revision" => 6})

    assert [
             result = %{
               "charged_back_cents" => 290,
               "revision" => 7,
               "outstanding_deposit_cents" => 100
             }
           ] = submit(conn, [operation])

    assert_statement(conn, "payment", %{
      recorded_cents: 300,
      reduced_cents: 10,
      charged_back_cents: 290
    })

    assert Map.take(
             ledger(conn),
             ~w(cash_refunded_cents cash_retained_cents cash_converted_to_credit_cents cash_charged_back_cents credit_liability_cents)
           ) == %{
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_charged_back_cents" => 290,
             "credit_liability_cents" => 0
           }

    before = snapshot()
    assert submit(conn, [operation, original]) == [result, original_result]
    assert snapshot() == before
    assert [%{"code" => "payment_not_chargeable"}] = submit(conn, [chargeback()])

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [Map.put(operation, "expected_revision", 7)])
  end

  test "chargeback of held cash preserves other funding, works after cancellation, and never refunds twice",
       %{conn: conn} do
    submit(conn, [
      small_group(),
      payment(%{"operation_id" => "payment", "amount_cents" => 180}),
      payment(%{"operation_id" => "second", "amount_cents" => 90}),
      reduction(),
      room_cancellation(%{"room_ids" => ["z"]})
    ])

    assert [%{"charged_back_cents" => 130, "revision" => 6, "outstanding_deposit_cents" => 110}] =
             submit(conn, [chargeback()])

    assert cash_by_room(conn) == [0, 20, 70]

    assert_statement(conn, "payment", %{
      recorded_cents: 180,
      reduced_cents: 50,
      charged_back_cents: 130
    })

    assert [%{"refunded_cents" => 90}] = submit(conn, [cancellation()])

    assert [%{"charged_back_cents" => 90, "revision" => 8, "outstanding_deposit_cents" => 0}] =
             submit(conn, [chargeback(%{"payment_operation_id" => "second"})])

    assert group(conn)["status"] == "cancelled"
    assert ledger(conn)["cash_refunded_cents"] == 0
    assert ledger(conn)["cash_charged_back_cents"] == 220
  end

  test "rounded entitlements follow funding order independently for each cancellation lot", %{
    conn: conn
  } do
    submit(conn, [
      small_group(%{"rooms" => rooms([{"z", 25}, {"a", 25}, {"m", 25}])}),
      payment(%{"operation_id" => "z-first", "amount_cents" => 5, "occurred_on" => "2026-11-03"}),
      payment(%{
        "operation_id" => "a-second",
        "amount_cents" => 10,
        "occurred_on" => "2026-10-31"
      })
    ])

    submit(conn, [
      room_cancellation(%{
        "operation_id" => "lot-one",
        "room_ids" => ["a", "z"],
        "refund_method" => "hotel_credit"
      }),
      room_cancellation(%{
        "operation_id" => "lot-two",
        "room_ids" => ["m"],
        "refund_method" => "hotel_credit"
      })
    ])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 17

    assert [%{"charged_back_cents" => 10}] =
             submit(conn, [chargeback(%{"payment_operation_id" => "a-second"})])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).lots == [
             %{source_operation_id: "lot-one", expires_on: ~D[2027-11-01], remaining_cents: 6}
           ]

    assert_statement(conn, "z-first", %{recorded_cents: 5, converted_to_credit_cents: 5})

    assert [%{"charged_back_cents" => 5}] =
             submit(conn, [chargeback(%{"payment_operation_id" => "z-first"})])

    assert ledger(conn)["credit_liability_cents"] == 0
  end

  test "clawback removes fungible remaining credit first and restoration absorbs shortfall before expiry",
       %{conn: conn} do
    seed_credit(conn, 100, "payment")
    submit(conn, [small_group(), credit_application(%{"amount_cents" => 100})])
    target = group(conn)

    assert [%{"charged_back_cents" => 100, "group_id" => "source", "revision" => 4}] =
             submit(conn, [chargeback()])

    assert group(conn) == target
    assert ledger(conn)["credit_liability_cents"] == 100
    assert ledger(conn)["credit_shortfall_cents"] == 100
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 0
    submit(conn, [reschedule(%{"new_arrival_on" => "2028-01-01"})])

    assert [%{"refunded_cents" => 0}] =
             submit(conn, [
               room_cancellation(%{"room_ids" => ["z"], "occurred_on" => "2027-12-01"})
             ])

    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
    assert [%CreditLot{remaining_cents: 0, unrecovered_clawback_cents: 0}] = Repo.all(CreditLot)
  end

  test "nonrefundable credit settlement reduces current shortfall without making credit available",
       %{conn: conn} do
    seed_credit(conn, 100, "payment")
    submit(conn, [small_group(), credit_application(%{"amount_cents" => 110}), chargeback()])
    assert ledger(conn)["credit_shortfall_cents"] == 110
    submit(conn, [room_cancellation(%{"room_ids" => ["z"], "occurred_on" => "2026-12-01"})])
    assert ledger(conn)["credit_shortfall_cents"] == 10
    assert ledger(conn)["credit_liability_cents"] == 10
    submit(conn, [cancellation(%{"occurred_on" => "2026-12-01"})])
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
    assert [%CreditLot{remaining_cents: 0, unrecovered_clawback_cents: 110}] = Repo.all(CreditLot)
  end

  test "restoration beyond a clawback becomes available with original expiry and no second bonus",
       %{conn: conn} do
    submit(conn, [
      small_group(%{"group_id" => "source"}),
      payment(%{"group_id" => "source", "operation_id" => "payment", "amount_cents" => 50}),
      payment(%{"group_id" => "source", "amount_cents" => 50}),
      cancellation(%{
        "group_id" => "source",
        "operation_id" => "lot",
        "refund_method" => "hotel_credit"
      }),
      small_group(),
      credit_application(%{"amount_cents" => 110}),
      chargeback()
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 55
    submit(conn, [room_cancellation(%{"room_ids" => ["z"], "refund_method" => "hotel_credit"})])
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 55
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 45
    assert Reservations.guest_credit("guest-22", ~D[2027-11-02]).available_cents == 0
    assert Reservations.ledger(~D[2027-11-02]).credit_liability_cents == 10
    submit(conn, [cancellation()])
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 55
  end

  test "rejected corrections and room cancellations retain exact results after conditions change",
       %{conn: conn} do
    early = reduction(%{"operation_id" => "early"})
    [rejected] = submit(conn, [early])
    submit(conn, [small_group(), payment(%{"operation_id" => "payment", "amount_cents" => 100})])
    assert submit(conn, [early]) == [rejected]

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [Map.put(early, "amount_cents", 1)])

    stale = room_cancellation(%{"room_ids" => ["z"], "expected_revision" => 1})
    [stale_result] = submit(conn, [stale])
    submit(conn, [chargeback()])
    assert submit(conn, [stale]) == [stale_result]

    assert conn |> get("/api/v1/operations/#{stale["operation_id"]}") |> json_response(200) == %{
             "data" => stale_result
           }
  end

  test "partial cancellations use the fixed policy and rescheduled deadline", %{conn: conn} do
    submit(conn, [
      small_group(%{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2028-03-01",
        "departure_on" => "2028-03-02"
      }),
      payment(%{"amount_cents" => 300}),
      reschedule(%{"new_arrival_on" => "2028-04-01"})
    ])

    assert group(conn)["policy_version"] == "flex-30"
    assert group(conn)["refundable_until"] == "2028-03-02"

    assert [%{"refunded_cents" => 100}] =
             submit(conn, [
               room_cancellation(%{"room_ids" => ["z"], "occurred_on" => "2028-03-02"})
             ])

    assert [%{"retained_cents" => 100}] =
             submit(conn, [
               room_cancellation(%{"room_ids" => ["a"], "occurred_on" => "2028-03-03"})
             ])

    assert [%{"code" => "invalid_rooms"}] =
             submit(conn, [room_cancellation(%{"room_ids" => ["z"]})])
  end

  test "advance purchase settles selected rooms nonrefundably and later funding skips cancelled rooms",
       %{conn: conn} do
    submit(conn, [
      small_group(%{"rate_plan" => "advance_purchase"}),
      payment(%{"operation_id" => "payment", "amount_cents" => 600})
    ])

    assert [%{"code" => "refund_method_not_available"}] =
             submit(conn, [
               room_cancellation(%{"room_ids" => ["z"], "refund_method" => "hotel_credit"})
             ])

    assert [%{"retained_cents" => 500}] =
             submit(conn, [room_cancellation(%{"room_ids" => ["z"]})])

    submit(conn, [payment(%{"amount_cents" => 450})])
    assert cash_by_room(conn) == [0, 500, 50]

    assert_statement(conn, "payment", %{recorded_cents: 600, held_cents: 100, retained_cents: 500})
  end

  test "shortfalls are capped separately per lot even when another lot funds the same group", %{
    conn: conn
  } do
    seed_credit(conn, 100, "payment")

    submit(conn, [
      small_group(%{"group_id" => "source-two"}),
      payment(%{"group_id" => "source-two", "operation_id" => "second", "amount_cents" => 100}),
      cancellation(%{
        "group_id" => "source-two",
        "operation_id" => "z-second-lot",
        "refund_method" => "hotel_credit"
      }),
      small_group(),
      credit_application(%{"amount_cents" => 210}),
      chargeback()
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 110
    submit(conn, [room_cancellation(%{"room_ids" => ["z"], "occurred_on" => "2026-12-01"})])
    assert ledger(conn)["credit_shortfall_cents"] == 10
    assert ledger(conn)["credit_liability_cents"] == 120

    assert [%{"charged_back_cents" => 100}] =
             submit(conn, [chargeback(%{"payment_operation_id" => "second"})])

    assert ledger(conn)["credit_shortfall_cents"] == 110
    submit(conn, [room_cancellation(%{"room_ids" => ["a"]})])
    assert ledger(conn)["credit_shortfall_cents"] == 10
    submit(conn, [cancellation()])
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  test "revoking expired unspent credit creates no shortfall or negative liability", %{conn: conn} do
    seed_credit(conn, 100, "payment")
    assert Reservations.ledger(~D[2027-11-02]).credit_liability_cents == 0

    assert [%{"charged_back_cents" => 100}] =
             submit(conn, [chargeback(%{"occurred_on" => "2027-11-02"})])

    assert Reservations.ledger(~D[2027-11-02]).credit_liability_cents == 0
    assert Reservations.ledger(~D[2027-11-02]).credit_shortfall_cents == 0
    assert [%CreditLot{remaining_cents: 0, unrecovered_clawback_cents: 0}] = Repo.all(CreditLot)
  end

  test "payment corrections derive the group solely from the target and retain unusable targets",
       %{conn: conn} do
    missing_target = chargeback() |> Map.delete("payment_operation_id")
    assert [%{"code" => "invalid_operation"}] = submit(conn, [missing_target])
    submit(conn, [small_group(), payment(%{"operation_id" => "payment", "amount_cents" => 50})])

    operation =
      reduction(%{"amount_cents" => 20, "expected_revision" => 2})
      |> Map.put("group_id", "missing")

    assert [%{"group_id" => "group-81", "revision" => 3}] = submit(conn, [operation])

    assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
             submit(conn, [
               chargeback(%{"expected_revision" => 2}) |> Map.put("occurred_on", "bad")
             ])
  end

  test "repeated funding and reductions retain exact cents beyond SQLite's cumulative integer range",
       %{conn: conn} do
    amount = 9_223_372_036_854_775_807

    submit(conn, [
      small_group(%{"rate_plan" => "advance_purchase", "rooms" => rooms([{"large", amount}])}),
      payment(%{"operation_id" => "payment", "amount_cents" => amount}),
      reduction(%{"amount_cents" => amount}),
      payment(%{"operation_id" => "second", "amount_cents" => amount})
    ])

    assert ledger(conn)["cash_held_cents"] == amount
    assert ledger(conn)["cash_reduced_cents"] == amount
    assert_statement(conn, "payment", %{recorded_cents: amount, reduced_cents: amount})

    assert [%{"charged_back_cents" => ^amount}] =
             submit(conn, [chargeback(%{"payment_operation_id" => "second"})])

    assert ledger(conn)["cash_held_cents"] == 0
    assert ledger(conn)["cash_charged_back_cents"] == amount
  end

  defp small_group(overrides \\ %{}) do
    open_group(
      Map.merge(
        %{"departure_on" => "2026-12-11", "rooms" => rooms([{"z", 500}, {"a", 500}, {"m", 500}])},
        overrides
      )
    )
  end

  defp rooms(rates),
    do: Enum.map(rates, fn {id, rate} -> %{"room_id" => id, "nightly_rate_cents" => rate} end)

  defp seed_credit(conn, amount, payment_id \\ "source-payment") do
    submit(conn, [
      small_group(%{"group_id" => "source"}),
      payment(%{"group_id" => "source", "operation_id" => payment_id, "amount_cents" => amount}),
      cancellation(%{
        "group_id" => "source",
        "operation_id" => "source-credit",
        "refund_method" => "hotel_credit"
      })
    ])
  end

  defp submit(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp group(conn),
    do: conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn),
    do: conn |> get("/api/v1/ledger?on=2026-11-01") |> json_response(200) |> Map.fetch!("data")

  defp cash_by_room(conn), do: Enum.map(group(conn)["rooms"], & &1["cash_paid_cents"])

  defp assert_statement(conn, id, amounts) do
    expected =
      Map.merge(
        %{
          payment_operation_id: id,
          original_group_id: "group-81",
          recorded_cents: 0,
          held_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          reduced_cents: 0,
          charged_back_cents: 0
        },
        amounts
      )

    before = snapshot()
    actual = conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")
    assert actual == Jason.decode!(Jason.encode!(expected))

    assert Enum.sum(
             Map.values(
               Map.drop(actual, ~w(payment_operation_id original_group_id recorded_cents))
             )
           ) == actual["recorded_cents"]

    assert snapshot() == before
  end

  defp snapshot,
    do:
      Enum.map(
        [
          Group,
          CashEntry,
          CashAllocation,
          CreditLot,
          CreditAllocation,
          RoomCreditAllocation,
          CreditEntitlement
        ],
        &Repo.all/1
      )
end
