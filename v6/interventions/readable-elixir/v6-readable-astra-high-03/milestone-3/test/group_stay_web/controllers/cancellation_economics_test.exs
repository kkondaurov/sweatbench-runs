defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures

  alias GroupStay.Credit.{Allocation, Lot}
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  for {booked_on, plan, policy, deadline} <- [
        {"2026-12-31", "flexible", "flex-14", "2027-02-16"},
        {"2027-01-01", "flexible", "flex-30", "2027-01-31"},
        {"2027-01-01", "advance_purchase", "advance-nonrefundable", nil}
      ] do
    test "fixes #{policy} for a #{plan} booking on #{booked_on}", %{conn: conn} do
      applied(conn, [
        open_group(%{
          "occurred_on" => unquote(booked_on),
          "rate_plan" => unquote(plan),
          "arrival_on" => "2027-03-02",
          "departure_on" => "2027-03-05"
        })
      ])

      assert %{"policy_version" => unquote(policy), "refundable_until" => unquote(deadline)} =
               group(conn)

      [result] =
        applied(conn, [
          operation("reschedule_group", %{
            "occurred_on" => "2028-01-01",
            "new_arrival_on" => "2028-03-15",
            "expected_revision" => 1
          })
        ])

      assert result["policy_version"] == unquote(policy)
      assert result["new_departure_on"] == "2028-03-18"
      assert result["revision"] == 2

      expected =
        case unquote(policy) do
          "flex-14" -> "2028-03-01"
          "flex-30" -> "2028-02-14"
          "advance-nonrefundable" -> nil
        end

      assert result["refundable_until"] == expected
      assert group(conn)["refundable_until"] == expected
    end
  end

  for {date, refunded, retained} <- [
        {"2027-01-30", 500, 0},
        {"2027-01-31", 500, 0},
        {"2027-02-01", 0, 500}
      ] do
    test "new flexible policy settles cash on #{date}", %{conn: conn} do
      [_, _, result] =
        applied(conn, [
          open_group(%{
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-02",
            "departure_on" => "2027-03-05"
          }),
          operation("record_cash_payment", %{"amount_cents" => 500, "occurred_on" => "2027-01-02"}),
          operation("cancel_group", %{"occurred_on" => unquote(date)})
        ])

      assert result["refunded_cents"] == unquote(refunded)
      assert result["retained_cents"] == unquote(retained)
      assert result["credit_issued_cents"] == 0
      assert ledger(conn, unquote(date))["credit_liability_cents"] == 0
    end
  end

  test "hotel credit bonus rounds half upward, with no lot for unpaid cash", %{conn: conn} do
    for {cash, issued} <- [{0, 0}, {4, 4}, {5, 6}, {6, 7}, {15, 17}] do
      result = issue(conn, "bonus-#{cash}", cash)
      assert result["credit_issued_cents"] == issued
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["revision"] == if(cash == 0, do: 2, else: 3)
    end

    assert %{"available_cents" => 34, "lots" => lots} = credit(conn, "2026-10-04")
    assert length(lots) == 4
    assert Enum.all?(lots, &(&1["expires_on"] == "2027-10-04"))
    assert ledger(conn, "2026-10-04") == totals(0, 0, 0, 30, 34)
  end

  test "credit expiry is 365 calendar days across leap years", %{conn: conn} do
    issue(conn, "leap", 100, "2028-02-29")
    assert [%{"expires_on" => "2029-02-28"}] = credit(conn, "2029-02-28")["lots"]
    assert credit(conn, "2029-03-01")["available_cents"] == 0
    assert ledger(conn, "2029-03-01")["credit_liability_cents"] == 0
  end

  test "rescheduled bookings settle using their original window", %{conn: conn} do
    for {booked, id, refunded, retained} <- [
          {"2026-12-31", "old", 100, 0},
          {"2027-01-01", "new", 0, 100}
        ] do
      results =
        applied(conn, [
          open_group(%{
            "group_id" => id,
            "occurred_on" => booked,
            "arrival_on" => "2027-04-02",
            "departure_on" => "2027-04-05"
          }),
          operation("record_cash_payment", %{
            "group_id" => id,
            "amount_cents" => 100,
            "occurred_on" => "2027-01-02"
          }),
          operation("reschedule_group", %{
            "group_id" => id,
            "occurred_on" => "2027-01-02",
            "new_arrival_on" => "2027-03-02"
          }),
          operation("cancel_group", %{"group_id" => id, "occurred_on" => "2027-02-10"})
        ])

      assert List.last(results)["refunded_cents"] == refunded
      assert List.last(results)["retained_cents"] == retained
    end
  end

  test "credit lots are consumed by expiry then source identifier and restored exactly", %{
    conn: conn
  } do
    issue(conn, "z", 100, "2026-10-05")
    issue(conn, "a", 100, "2026-10-05")
    issue(conn, "later", 100, "2026-10-06")
    issue(conn, "earlier", 100, "2026-10-04")
    original = credit(conn, "2026-10-06")
    assert Enum.map(original["lots"], & &1["source_operation_id"]) == ~w(earlier a z later)

    [_, result] =
      applied(conn, [
        open_group(),
        operation("apply_hotel_credit", %{
          "operation_id" => "apply_hotel_credit-1",
          "amount_cents" => 150,
          "occurred_on" => "2026-10-06",
          "expected_revision" => 1
        })
      ])

    assert result == %{
             "operation_id" => "apply_hotel_credit-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 150,
             "outstanding_deposit_cents" => 19_350,
             "revision" => 2
           }

    assert Enum.map(credit(conn, "2026-10-06")["lots"], fn lot ->
             {lot["source_operation_id"], lot["remaining_cents"]}
           end) == [{"a", 70}, {"z", 110}, {"later", 110}]

    applied(conn, [
      operation("apply_hotel_credit", %{"amount_cents" => 70, "occurred_on" => "2026-10-06"})
    ])

    assert Repo.aggregate(Allocation, :count) == 2

    assert %{"cash_paid_cents" => 0, "credit_paid_cents" => 220, "deposit_paid_cents" => 220} =
             group(conn)

    assert ledger(conn, "2026-10-06") == totals(0, 0, 0, 400, 440)

    [result] =
      applied(conn, [
        operation("cancel_group", %{
          "refund_method" => "hotel_credit",
          "occurred_on" => "2026-10-06"
        })
      ])

    assert result["credit_issued_cents"] == 0
    assert credit(conn, "2026-10-06") == original
    assert Repo.aggregate(Allocation, :count) == 0
    assert group(conn)["credit_paid_cents"] == 0
  end

  test "mixed funding converts only cash and never gives restored credit a second bonus", %{
    conn: conn
  } do
    issue(conn, "original", 1_000)

    [_, _, _, result] =
      applied(conn, [
        open_group(),
        operation("apply_hotel_credit", %{"amount_cents" => 600}),
        operation("record_cash_payment", %{"amount_cents" => 500}),
        operation("cancel_group", %{"refund_method" => "hotel_credit", "operation_id" => "new"})
      ])

    assert result["credit_issued_cents"] == 550
    assert result["revision"] == 4
    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 0

    assert credit(conn, "2026-10-04")["lots"] == [
             %{
               "source_operation_id" => "new",
               "remaining_cents" => 550,
               "expires_on" => "2027-10-04"
             },
             %{
               "source_operation_id" => "original",
               "remaining_cents" => 1_100,
               "expires_on" => "2027-10-04"
             }
           ]

    assert ledger(conn, "2026-10-04") == totals(0, 0, 0, 1_500, 1_650)

    assert %{
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 0,
             "status" => "cancelled"
           } = group(conn)
  end

  test "cash refund restores applied credit to its lot and refunds only cash", %{conn: conn} do
    issue(conn, "original", 1_000)

    applied(conn, [
      open_group(),
      operation("apply_hotel_credit", %{"amount_cents" => 600}),
      operation("record_cash_payment", %{"amount_cents" => 500})
    ])

    assert %{"cash_paid_cents" => 500, "credit_paid_cents" => 600, "deposit_paid_cents" => 1_100} =
             group(conn)

    assert ledger(conn, "2026-10-04") == totals(500, 0, 0, 1_000, 1_100)

    [result] = applied(conn, [operation("cancel_group")])
    assert result["refunded_cents"] == 500
    assert result["retained_cents"] == 0
    assert result["credit_issued_cents"] == 0
    assert credit(conn, "2026-10-04")["available_cents"] == 1_100
    assert ledger(conn, "2026-10-04") == totals(0, 500, 0, 1_000, 1_100)
  end

  for {plan, cancel_on} <- [{"flexible", "2026-11-27"}, {"advance_purchase", "2026-10-04"}] do
    test "non-refundable #{plan} rejects credit conversion and consumes applied credit", %{
      conn: conn
    } do
      issue(conn, "original", 1_000)

      applied(conn, [
        open_group(%{"rate_plan" => unquote(plan)}),
        operation("apply_hotel_credit", %{"amount_cents" => 600}),
        operation("record_cash_payment", %{"amount_cents" => 500})
      ])

      before = snapshot()

      assert [%{"code" => "refund_method_not_available"}] =
               batch(conn, [
                 operation("cancel_group", %{
                   "occurred_on" => unquote(cancel_on),
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert snapshot() == before

      [result] =
        applied(conn, [
          operation("cancel_group", %{
            "occurred_on" => unquote(cancel_on),
            "expected_revision" => 3
          })
        ])

      assert result["revision"] == 4
      assert result["retained_cents"] == 500
      assert result["refunded_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert ledger(conn, unquote(cancel_on)) == totals(0, 0, 500, 1_000, 500)
      assert credit(conn, unquote(cancel_on))["available_cents"] == 500
      assert Repo.aggregate(Allocation, :count) == 0
    end
  end

  for {cancel_on, available} <- [{"2027-10-04", 1_100}, {"2027-10-05", 0}] do
    test "expiry is paused during funding and restoration on #{cancel_on} leaves #{available}", %{
      conn: conn
    } do
      issue(conn, "original", 1_000)

      applied(conn, [
        open_group(%{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-04"}),
        operation("apply_hotel_credit", %{"occurred_on" => "2027-10-04", "amount_cents" => 600})
      ])

      assert credit(conn, "2027-10-04")["available_cents"] == 500
      assert ledger(conn, "2027-10-04")["credit_liability_cents"] == 1_100

      assert credit(conn, "2027-10-05") == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }

      assert ledger(conn, "2027-10-05")["credit_liability_cents"] == 600

      applied(conn, [operation("cancel_group", %{"occurred_on" => unquote(cancel_on)})])
      assert credit(conn, unquote(cancel_on))["available_cents"] == unquote(available)
      assert ledger(conn, unquote(cancel_on))["credit_liability_cents"] == unquote(available)
      assert Repo.aggregate(Allocation, :count) == 0

      if unquote(available) == 0 do
        assert Repo.one!(Lot).remaining_cents == 500
      end
    end
  end

  test "expiry uses the operation date, insufficient credit is atomic, and guests are isolated",
       %{conn: conn} do
    issue(conn, "original", 1_000)

    applied(conn, [
      open_group(),
      open_group(%{"group_id" => "other", "guest_id" => "other-guest"})
    ])

    for overrides <- [
          %{"amount_cents" => 1_101},
          %{"amount_cents" => 1, "occurred_on" => "2027-10-05"},
          %{"amount_cents" => 1, "group_id" => "other"}
        ] do
      before = snapshot()

      assert [%{"code" => "insufficient_credit"}] =
               batch(conn, [operation("apply_hotel_credit", overrides)])

      assert snapshot() == before
    end

    applied(conn, [
      operation("apply_hotel_credit", %{"amount_cents" => 1_100, "occurred_on" => "2027-10-04"})
    ])

    assert credit(conn, "2027-10-04")["lots"] == []
    assert ledger(conn, "2027-10-05")["credit_liability_cents"] == 1_100
  end

  test "one settlement restores live lots, extinguishes expired allocations and converts cash", %{
    conn: conn
  } do
    issue(conn, "old", 500)
    issue(conn, "live", 1_000, "2027-04-01")

    applied(conn, [
      open_group(%{"arrival_on" => "2028-04-01", "departure_on" => "2028-04-04"}),
      operation("apply_hotel_credit", %{"amount_cents" => 800, "occurred_on" => "2027-10-04"}),
      operation("record_cash_payment", %{"amount_cents" => 200, "occurred_on" => "2027-10-04"})
    ])

    assert ledger(conn, "2027-10-05") == totals(200, 0, 0, 1_500, 1_650)

    [result] =
      applied(conn, [
        operation("cancel_group", %{
          "occurred_on" => "2027-10-05",
          "refund_method" => "hotel_credit",
          "operation_id" => " New-Ä ",
          "expected_revision" => 3
        })
      ])

    assert result["credit_issued_cents"] == 220
    assert result["revision"] == 4

    assert credit(conn, "2027-10-05")["lots"] == [
             %{
               "source_operation_id" => "live",
               "remaining_cents" => 1_100,
               "expires_on" => "2028-03-31"
             },
             %{
               "source_operation_id" => " New-Ä ",
               "remaining_cents" => 220,
               "expires_on" => "2028-10-04"
             }
           ]

    assert ledger(conn, "2027-10-05") == totals(0, 0, 0, 1_700, 1_320)
    assert Repo.aggregate(Allocation, :count) == 0
  end

  test "credit payment validation and revision precedence preserve every table", %{conn: conn} do
    issue(conn, "original", 1_000)
    applied(conn, [open_group()])

    invalid =
      for amount <- [nil, 0, -1, 1.5, "100", true, %{}],
          do: {operation("apply_hotel_credit", %{"amount_cents" => amount}), "invalid_amount"}

    invalid =
      invalid ++
        [
          {operation("apply_hotel_credit"), "invalid_operation"},
          {operation("apply_hotel_credit", %{"amount_cents" => 19_501}),
           "payment_exceeds_outstanding"},
          {operation("apply_hotel_credit", %{"amount_cents" => 1_101}), "insufficient_credit"},
          {operation("cancel_group", %{"refund_method" => "voucher"}), "invalid_operation"},
          {operation("cancel_group", %{"refund_method" => nil}), "invalid_operation"},
          {operation("cancel_group", %{
             "refund_method" => "hotel_credit",
             "occurred_on" => "2026-11-27"
           }), "refund_method_not_available"}
        ]

    for {op, code} <- invalid do
      before = snapshot()
      assert [%{"code" => ^code}] = batch(conn, [op])
      assert snapshot() == before

      assert [%{"code" => "stale_revision", "expected_revision" => 99, "actual_revision" => 1}] =
               batch(conn, [
                 Map.merge(op, %{
                   "expected_revision" => 99,
                   "operation_id" => op["operation_id"] <> "-stale"
                 })
               ])

      assert snapshot() == before
    end

    assert [%{"code" => "group_not_found"}] =
             batch(conn, [
               operation("apply_hotel_credit", %{
                 "group_id" => "missing",
                 "expected_revision" => 99
               })
             ])

    assert [
             %{"revision" => 2},
             %{"code" => "stale_revision"},
             %{"revision" => 3},
             %{"revision" => 4},
             %{"code" => "group_not_active"}
           ] =
             batch(conn, [
               operation("apply_hotel_credit", %{"amount_cents" => 100, "expected_revision" => 1}),
               operation("apply_hotel_credit", %{"amount_cents" => 100, "expected_revision" => 1}),
               operation("apply_hotel_credit", %{"amount_cents" => 100, "expected_revision" => 2}),
               operation("cancel_group", %{"expected_revision" => 3}),
               operation("apply_hotel_credit", %{"amount_cents" => 1})
             ])
  end

  test "cash and credit share the outstanding deposit limit", %{conn: conn} do
    issue(conn, "original", 1_000)
    applied(conn, [open_group(), operation("record_cash_payment", %{"amount_cents" => 19_000})])

    assert [
             %{"code" => "payment_exceeds_outstanding"},
             %{"outstanding_deposit_cents" => 0},
             %{"code" => "payment_exceeds_outstanding"}
           ] =
             batch(conn, [
               operation("apply_hotel_credit", %{"amount_cents" => 501}),
               operation("apply_hotel_credit", %{"amount_cents" => 500}),
               operation("record_cash_payment", %{"amount_cents" => 1})
             ])

    assert %{
             "deposit_paid_cents" => 19_500,
             "cash_paid_cents" => 19_000,
             "credit_paid_cents" => 500
           } = group(conn)
  end

  test "credit and ledger reads default to UTC today and reject invalid date queries", %{
    conn: conn
  } do
    today = Date.utc_today()
    issue(conn, "expired", 100, today |> Date.add(-366) |> Date.to_iso8601())
    issue(conn, "last-day", 200, today |> Date.add(-365) |> Date.to_iso8601())
    issue(conn, "current", 300, Date.to_iso8601(today))

    assert get_data(conn, "/api/v1/guests/guest-22/credit") ==
             credit(conn, Date.to_iso8601(today))

    assert get_data(conn, "/api/v1/ledger") == ledger(conn, Date.to_iso8601(today))
    assert get_data(conn, "/api/v1/guests/guest-22/credit")["available_cents"] == 550

    assert get_data(conn, "/api/v1/guests/unknown/credit") == %{
             "guest_id" => "unknown",
             "available_cents" => 0,
             "lots" => []
           }

    for endpoint <- ["/api/v1/guests/guest-22/credit", "/api/v1/ledger"],
        query <- ["on=bad", "on=2027-02-29", "on=", "on[]=2027-01-01"] do
      assert conn |> recycle() |> get(endpoint <> "?" <> query) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end
  end

  defp issue(conn, source, cash, on \\ "2026-10-04") do
    date = Date.from_iso8601!(on)

    opening =
      open_group(%{
        "group_id" => "source-#{source}",
        "occurred_on" => on,
        "arrival_on" => date |> Date.add(60) |> Date.to_iso8601(),
        "departure_on" => date |> Date.add(63) |> Date.to_iso8601()
      })

    payment =
      operation("record_cash_payment", %{
        "group_id" => opening["group_id"],
        "amount_cents" => cash,
        "occurred_on" => on
      })

    cancellation =
      operation("cancel_group", %{
        "group_id" => opening["group_id"],
        "operation_id" => source,
        "occurred_on" => on,
        "refund_method" => "hotel_credit"
      })

    operations = if cash == 0, do: [opening, cancellation], else: [opening, payment, cancellation]
    applied(conn, operations) |> List.last()
  end

  defp applied(conn, operations) do
    results = batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp batch(conn, operations) do
    conn
    |> recycle()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn), do: get_data(conn, "/api/v1/groups/group-81")
  defp credit(conn, on), do: get_data(conn, "/api/v1/guests/guest-22/credit?on=#{on}")
  defp ledger(conn, on), do: get_data(conn, "/api/v1/ledger?on=#{on}")

  defp get_data(conn, path),
    do: conn |> recycle() |> get(path) |> json_response(200) |> Map.fetch!("data")

  defp snapshot, do: {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation)}

  defp totals(held, refunded, retained, converted, liability) do
    %{
      "cash_held_cents" => held,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained,
      "cash_converted_to_credit_cents" => converted,
      "credit_liability_cents" => liability
    }
  end
end
