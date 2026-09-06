defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerFixtures

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group, Room}

  test "booking cutover fixes the policy and cancellation is inclusive of each cutoff", %{
    conn: conn
  } do
    cases = [
      {"old-early", "2026-12-31", "flexible", "flex-14", "2027-02-15", "2027-02-14", 100},
      {"old-edge", "2026-12-31", "flexible", "flex-14", "2027-02-15", "2027-02-15", 100},
      {"old-late", "2026-12-31", "flexible", "flex-14", "2027-02-15", "2027-02-16", 0},
      {"new-early", "2027-01-01", "flexible", "flex-30", "2027-01-30", "2027-01-29", 100},
      {"new-edge", "2027-01-01", "flexible", "flex-30", "2027-01-30", "2027-01-30", 100},
      {"new-late", "2027-01-01", "flexible", "flex-30", "2027-01-30", "2027-01-31", 0},
      {"advance", "2027-01-01", "advance_purchase", "advance-nonrefundable", nil, "2027-01-01", 0}
    ]

    for {id, booked, plan, policy, cutoff, cancelled, refunded} <- cases do
      assert [%{"revision" => 1}, %{"revision" => 2}] =
               batch(conn, [
                 open_operation(%{
                   "group_id" => id,
                   "occurred_on" => booked,
                   "rate_plan" => plan,
                   "arrival_on" => "2027-03-01",
                   "departure_on" => "2027-03-04"
                 }),
                 op("record_cash_payment", id, booked, %{"amount_cents" => 100})
               ])

      assert %{"policy_version" => ^policy, "refundable_until" => ^cutoff} = group(conn, id)
      retained = 100 - refunded

      assert [
               %{
                 "refunded_cents" => ^refunded,
                 "retained_cents" => ^retained,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] =
               batch(conn, [op("cancel_group", id, cancelled)])
    end
  end

  test "reschedules preserve both policies across the cutover and recompute leap-day cutoffs", %{
    conn: conn
  } do
    for {id, booked, policy, cutoff} <- [
          {"old", "2026-12-31", "flex-14", "2028-02-16"},
          {"new", "2027-01-01", "flex-30", "2028-01-31"},
          {"advance", "2027-01-01", "advance-nonrefundable", nil}
        ] do
      plan = if id == "advance", do: "advance_purchase", else: "flexible"

      batch(conn, [
        open_operation(%{"group_id" => id, "occurred_on" => booked, "rate_plan" => plan})
      ])

      assert [
               %{
                 "revision" => 2,
                 "policy_version" => ^policy,
                 "refundable_until" => ^cutoff,
                 "new_arrival_on" => "2028-03-01",
                 "new_departure_on" => "2028-03-04"
               }
             ] =
               batch(conn, [
                 op("reschedule_group", id, "2027-01-02", %{"new_arrival_on" => "2028-03-01"})
               ])

      assert %{"booked_on" => ^booked, "policy_version" => ^policy, "refundable_until" => ^cutoff} =
               group(conn, id)
    end
  end

  test "credit issuance rounds the cash bonus, preserves identifiers and expires after 365 days",
       %{conn: conn} do
    for {cash, issued} <- [{4, 4}, {5, 6}, {6, 7}, {15, 17}, {5000, 5500}] do
      source = " Cancel-Ä #{cash} "

      assert %{
               "credit_issued_cents" => ^issued,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "revision" => 3
             } =
               issue(conn, source, cash, "2027-05-03", " Guest-Ä ")
    end

    credit = credit(conn, " Guest-Ä ", "2028-05-02")
    assert credit["guest_id"] == " Guest-Ä "
    assert credit["available_cents"] == 5534

    assert Enum.map(credit["lots"], & &1["source_operation_id"]) ==
             [" Cancel-Ä 15 ", " Cancel-Ä 4 ", " Cancel-Ä 5 ", " Cancel-Ä 5000 ", " Cancel-Ä 6 "]

    assert Enum.all?(credit["lots"], &(&1["expires_on"] == "2028-05-02"))
    assert credit(conn, "guest-22", "2027-05-03")["available_cents"] == 0

    assert ledger(conn, "2028-05-02") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "cash_converted_to_credit_cents" => 5030,
             "credit_liability_cents" => 5534
           }

    assert credit(conn, " Guest-Ä ", "2028-05-03")["lots"] == []
    assert ledger(conn, "2028-05-03")["credit_liability_cents"] == 0
    # Reads are projections of expiry, not destructive sweeps.
    assert credit(conn, " Guest-Ä ", "2028-05-02") == credit
  end

  test "application consumes by expiry then source, across properties, and supports repeated funding",
       %{conn: conn} do
    issue(conn, "z", 100, "2027-01-01")
    issue(conn, "b", 100, "2027-01-02")
    issue(conn, "a", 100, "2027-01-02")
    issue(conn, "foreign", 100, "2027-01-01", "other-guest")

    assert [
             %{"revision" => 1},
             %{"revision" => 2, "outstanding_deposit_cents" => 19390},
             %{"revision" => 3, "outstanding_deposit_cents" => 19340},
             %{"revision" => 4, "outstanding_deposit_cents" => 19280},
             %{"revision" => 5, "outstanding_deposit_cents" => 19260}
           ] =
             batch(conn, [
               open_operation(%{"group_id" => "target", "property_id" => "another-hotel"}),
               op("apply_hotel_credit", "target", "2027-02-01", %{
                 "amount_cents" => 110,
                 "expected_revision" => 1
               }),
               op("apply_hotel_credit", "target", "2027-02-01", %{
                 "amount_cents" => 50,
                 "expected_revision" => 2
               }),
               op("apply_hotel_credit", "target", "2027-02-01", %{
                 "amount_cents" => 60,
                 "expected_revision" => 3
               }),
               op("record_cash_payment", "target", "2027-02-01", %{
                 "amount_cents" => 20,
                 "expected_revision" => 4
               })
             ])

    assert %{"deposit_paid_cents" => 240, "cash_paid_cents" => 20, "credit_paid_cents" => 220} =
             group(conn, "target")

    assert credit(conn, "guest-22", "2027-02-01")["lots"] == [
             %{
               "source_operation_id" => "b",
               "remaining_cents" => 110,
               "expires_on" => "2028-01-02"
             }
           ]

    assert ledger(conn, "2027-02-01")["credit_liability_cents"] == 440
    assert ledger(conn, "2027-02-01")["cash_held_cents"] == 20
  end

  test "mixed refundable funding restores original credit and only cash can receive a bonus", %{
    conn: conn
  } do
    for method <- ["cash", "hotel_credit"] do
      guest = "guest-#{method}"
      issue(conn, "original-#{method}", 100, "2027-01-01", guest)
      target = "target-#{method}"

      batch(conn, [
        open_operation(%{
          "group_id" => target,
          "guest_id" => guest,
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-04"
        }),
        op("apply_hotel_credit", target, "2027-06-01", %{"amount_cents" => 80}),
        op("record_cash_payment", target, "2027-06-01", %{"amount_cents" => 105})
      ])

      refunded = if method == "cash", do: 105, else: 0
      issued = if method == "cash", do: 0, else: 116

      assert [
               %{
                 "refunded_cents" => ^refunded,
                 "retained_cents" => 0,
                 "credit_issued_cents" => ^issued,
                 "revision" => 4
               }
             ] =
               batch(conn, [
                 op("cancel_group", target, "2027-07-01", %{
                   "refund_method" => method,
                   "expected_revision" => 3
                 })
               ])

      assert %{
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0,
               "status" => "cancelled"
             } = group(conn, target)

      lots = credit(conn, guest, "2027-07-01")["lots"]

      assert hd(lots) == %{
               "source_operation_id" => "original-#{method}",
               "remaining_cents" => 110,
               "expires_on" => "2028-01-01"
             }

      assert Enum.sum(Enum.map(lots, & &1["remaining_cents"])) == 110 + issued
      assert length(lots) == if(method == "cash", do: 1, else: 2)
    end

    assert ledger(conn, "2027-07-01") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 105,
             "cash_retained_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "cash_converted_to_credit_cents" => 305,
             "credit_liability_cents" => 336
           }
  end

  test "credit expiry pauses while applied, with restoration inclusive only through original expiry",
       %{conn: conn} do
    issue(conn, "source", 100, "2027-01-01")

    batch(conn, [
      open_operation(%{
        "group_id" => "boundary",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      }),
      open_operation(%{
        "group_id" => "expired",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      }),
      op("apply_hotel_credit", "boundary", "2028-01-01", %{"amount_cents" => 40}),
      op("apply_hotel_credit", "expired", "2028-01-01", %{"amount_cents" => 50})
    ])

    assert credit(conn, "guest-22", "2028-01-01")["available_cents"] == 20
    assert ledger(conn, "2028-01-01")["credit_liability_cents"] == 110
    assert credit(conn, "guest-22", "2028-01-02")["available_cents"] == 0
    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 90

    batch(conn, [op("cancel_group", "boundary", "2028-01-01")])
    assert credit(conn, "guest-22", "2028-01-01")["available_cents"] == 60
    assert ledger(conn, "2028-01-01")["credit_liability_cents"] == 110
    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 50

    batch(conn, [
      op("cancel_group", "expired", "2028-01-02", %{"refund_method" => "hotel_credit"})
    ])

    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 0
    assert credit(conn, "guest-22", "2028-01-02")["lots"] == []
    assert Repo.one(CreditLot).remaining_cents == 60
    assert Repo.all(CreditAllocation) == []
  end

  test "late and advance cancellations retain cash and consume credit without cash inflation", %{
    conn: conn
  } do
    for {id, plan} <- [{"late", "flexible"}, {"advance", "advance_purchase"}] do
      issue(conn, "source-#{id}", 100, "2027-01-01")

      batch(conn, [
        open_operation(%{
          "group_id" => id,
          "occurred_on" => "2027-01-01",
          "rate_plan" => plan,
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        }),
        op("apply_hotel_credit", id, "2027-01-15", %{"amount_cents" => 110}),
        op("record_cash_payment", id, "2027-01-15", %{"amount_cents" => 75})
      ])

      reject_unchanged(
        conn,
        op("cancel_group", id, "2027-01-31", %{"refund_method" => "hotel_credit"}),
        "refund_method_not_available"
      )

      assert group(conn, id)["status"] == "active"

      assert [
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 75,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] =
               batch(conn, [op("cancel_group", id, "2027-01-31")])
    end

    assert ledger(conn, "2027-01-31") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 150,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "cash_converted_to_credit_cents" => 200,
             "credit_liability_cents" => 0
           }

    assert Repo.all(CreditAllocation) == []
  end

  test "credit and refund validation is atomic, revision-first, and batches continue after failures",
       %{conn: conn} do
    bad = [
      {operation("apply_hotel_credit"), "invalid_operation"},
      {operation("apply_hotel_credit", %{"amount_cents" => 0}), "invalid_amount"},
      {operation("apply_hotel_credit", %{"amount_cents" => 19501}),
       "payment_exceeds_outstanding"},
      {operation("apply_hotel_credit", %{"amount_cents" => 111}), "insufficient_credit"},
      {operation("cancel_group", %{"refund_method" => "voucher"}), "invalid_operation"}
    ]

    for {operation, _code} <- bad do
      reject_unchanged(conn, Map.put(operation, "expected_revision", 9), "group_not_found")
    end

    issue(conn, "available", 100, "2026-10-01")
    batch(conn, [open_operation()])

    for {operation, code} <- bad do
      reject_unchanged(
        conn,
        operation
        |> Map.put("operation_id", unique_operation_id())
        |> Map.put("expected_revision", 9),
        "stale_revision"
      )

      reject_unchanged(
        conn,
        operation
        |> Map.put("operation_id", unique_operation_id())
        |> Map.put("expected_revision", 1),
        code
      )
    end

    for amount <- [-1, 1.5, "100", nil, true, [], %{}, 9_223_372_036_854_775_808] do
      reject_unchanged(
        conn,
        operation("apply_hotel_credit", %{"amount_cents" => amount}),
        "invalid_amount"
      )
    end

    for method <- [nil, 1, true, [], %{}, ""] do
      reject_unchanged(
        conn,
        operation("cancel_group", %{"refund_method" => method}),
        "invalid_operation"
      )
    end

    assert [%{"code" => "insufficient_credit"}, %{"revision" => 2}, %{"revision" => 3}] =
             batch(conn, [
               operation("apply_hotel_credit", %{"amount_cents" => 111, "expected_revision" => 1}),
               operation("apply_hotel_credit", %{"amount_cents" => 110, "expected_revision" => 1}),
               operation("cancel_group", %{"expected_revision" => 2})
             ])

    reject_unchanged(
      conn,
      operation("apply_hotel_credit", %{"amount_cents" => 1, "expected_revision" => 2}),
      "stale_revision"
    )

    reject_unchanged(
      conn,
      operation("apply_hotel_credit", %{"amount_cents" => 1, "expected_revision" => 3}),
      "group_not_active"
    )
  end

  test "expiry uses the operation date and credit cannot cover another guest or an overpaid deposit",
       %{conn: conn} do
    issue(conn, "source", 100, "2026-01-01")

    batch(conn, [
      open_operation(),
      open_operation(%{"group_id" => "other", "guest_id" => "someone-else"})
    ])

    reject_unchanged(
      conn,
      op("apply_hotel_credit", "other", "2026-12-31", %{"amount_cents" => 1}),
      "insufficient_credit"
    )

    reject_unchanged(
      conn,
      op("apply_hotel_credit", "group-81", "2027-01-02", %{"amount_cents" => 1}),
      "insufficient_credit"
    )

    batch(conn, [operation("record_cash_payment", %{"amount_cents" => 19450})])

    reject_unchanged(
      conn,
      op("apply_hotel_credit", "group-81", "2027-01-01", %{"amount_cents" => 51}),
      "payment_exceeds_outstanding"
    )

    assert [%{"outstanding_deposit_cents" => 0, "revision" => 3}] =
             batch(conn, [
               op("apply_hotel_credit", "group-81", "2027-01-01", %{"amount_cents" => 50})
             ])

    reject_unchanged(
      conn,
      operation("record_cash_payment", %{"amount_cents" => 1}),
      "payment_exceeds_outstanding"
    )
  end

  test "unfunded refundable cancellations issue no lot and nonrefundable ones reject credit", %{
    conn: conn
  } do
    assert [
             _,
             %{
               "credit_issued_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "revision" => 2
             }
           ] =
             batch(conn, [
               open_operation(),
               operation("cancel_group", %{"refund_method" => "hotel_credit"})
             ])

    assert Repo.all(CreditLot) == []

    batch(conn, [open_operation(%{"group_id" => "advance", "rate_plan" => "advance_purchase"})])

    reject_unchanged(
      conn,
      op("cancel_group", "advance", "2026-11-01", %{
        "refund_method" => "hotel_credit",
        "expected_revision" => 0
      }),
      "stale_revision"
    )

    reject_unchanged(
      conn,
      op("cancel_group", "advance", "2026-11-01", %{"refund_method" => "hotel_credit"}),
      "refund_method_not_available"
    )
  end

  test "read dates default to UTC today and invalid dates return a stable client error", %{
    conn: conn
  } do
    today = Date.utc_today()
    issue(conn, "expires-yesterday", 100, today |> Date.add(-366) |> Date.to_iso8601())
    issue(conn, "expires-today", 100, today |> Date.add(-365) |> Date.to_iso8601())

    assert get_data(conn, "/api/v1/guests/guest-22/credit") ==
             credit(conn, "guest-22", Date.to_iso8601(today))

    assert get_data(conn, "/api/v1/ledger") == ledger(conn, Date.to_iso8601(today))
    assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 110

    assert credit(conn, "missing", "2027-01-01") == %{
             "guest_id" => "missing",
             "available_cents" => 0,
             "lots" => []
           }

    before = snapshot()

    for path <- ["/api/v1/ledger", "/api/v1/guests/guest-22/credit"],
        query <- ["on=bad", "on=2027-02-29", "on=", "on[]=2027-01-01", "on[x]=2027-01-01"] do
      assert conn |> recycle() |> get(path <> "?" <> query) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end

    assert snapshot() == before
  end

  test "a cancellation restores each funding lot independently and restored credit can fund another group",
       %{conn: conn} do
    issue(conn, "early", 100, "2027-01-01")
    issue(conn, "later", 100, "2027-02-01")

    batch(conn, [
      open_operation(%{
        "group_id" => "first",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      }),
      op("apply_hotel_credit", "first", "2027-06-01", %{"amount_cents" => 200}),
      op("reschedule_group", "first", "2027-07-01", %{"new_arrival_on" => "2028-07-01"})
    ])

    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 220

    assert [
             %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }
           ] =
             batch(conn, [
               op("cancel_group", "first", "2028-01-02", %{"refund_method" => "hotel_credit"})
             ])

    assert credit(conn, "guest-22", "2028-01-02")["lots"] == [
             %{
               "source_operation_id" => "later",
               "remaining_cents" => 110,
               "expires_on" => "2028-02-01"
             }
           ]

    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 110

    assert [_, %{"outstanding_deposit_cents" => 19390}, %{"credit_issued_cents" => 0}] =
             batch(conn, [
               open_operation(%{
                 "group_id" => "second",
                 "arrival_on" => "2028-06-01",
                 "departure_on" => "2028-06-04"
               }),
               op("apply_hotel_credit", "second", "2028-01-03", %{"amount_cents" => 110}),
               op("cancel_group", "second", "2028-01-04", %{"refund_method" => "hotel_credit"})
             ])

    assert credit(conn, "guest-22", "2028-01-04")["available_cents"] == 110
    assert ledger(conn, "2028-02-02")["credit_liability_cents"] == 0
  end

  test "credit arithmetic remains exact for large lots and totals exceeding SQLite integer sums",
       %{conn: conn} do
    maximum = 9_223_372_036_854_775_807
    cash = div(maximum * 20 + 50, 100)
    issued = cash + div(cash * 10 + 50, 100)

    for id <- 1..5 do
      group_id = "large-#{id}"

      assert [_, _, %{"credit_issued_cents" => ^issued}] =
               batch(conn, [
                 open_operation(%{
                   "group_id" => group_id,
                   "departure_on" => "2026-12-11",
                   "rooms" => [%{"room_id" => "large", "nightly_rate_cents" => maximum}]
                 }),
                 operation("record_cash_payment", %{
                   "group_id" => group_id,
                   "amount_cents" => cash
                 }),
                 operation("cancel_group", %{
                   "group_id" => group_id,
                   "operation_id" => "credit-#{id}",
                   "refund_method" => "hotel_credit"
                 })
               ])
    end

    assert credit(conn, "guest-22", "2026-11-01")["available_cents"] == issued * 5
    assert ledger(conn, "2026-11-01")["credit_liability_cents"] == issued * 5
    assert ledger(conn, "2026-11-01")["cash_converted_to_credit_cents"] == cash * 5

    assert [_, %{"outstanding_deposit_cents" => 0}] =
             batch(conn, [
               open_operation(%{
                 "group_id" => "maximum",
                 "rate_plan" => "advance_purchase",
                 "departure_on" => "2026-12-11",
                 "rooms" => [%{"room_id" => "large", "nightly_rate_cents" => maximum}]
               }),
               operation("apply_hotel_credit", %{
                 "group_id" => "maximum",
                 "amount_cents" => maximum
               })
             ])

    assert group(conn, "maximum")["credit_paid_cents"] == maximum
    assert group(conn, "maximum")["cash_paid_cents"] == 0
    assert ledger(conn, "2026-11-01")["credit_liability_cents"] == issued * 5

    assert [%{"retained_cents" => 0, "refunded_cents" => 0, "credit_issued_cents" => 0}] =
             batch(conn, [operation("cancel_group", %{"group_id" => "maximum"})])

    assert ledger(conn, "2026-11-01")["credit_liability_cents"] == issued * 5 - maximum
    assert ledger(conn, "2026-11-01")["cash_retained_cents"] == 0
  end

  test "credit expiry outside the supported date range rejects atomically and cash still works",
       %{conn: conn} do
    batch(conn, [
      open_operation(%{
        "occurred_on" => "9998-12-01",
        "arrival_on" => "9999-12-01",
        "departure_on" => "9999-12-04"
      }),
      op("record_cash_payment", "group-81", "9999-01-01", %{"amount_cents" => 100})
    ])

    reject_unchanged(
      conn,
      op("cancel_group", "group-81", "9999-01-01", %{"refund_method" => "hotel_credit"}),
      "invalid_operation"
    )

    assert [%{"refunded_cents" => 100, "revision" => 3}] =
             batch(conn, [op("cancel_group", "group-81", "9999-01-01")])
  end

  defp issue(conn, source, amount, on, guest \\ "guest-22") do
    arrival = on |> Date.from_iso8601!() |> Date.add(60)

    [_, _, result] =
      batch(conn, [
        open_operation(%{
          "group_id" => "source-#{source}",
          "guest_id" => guest,
          "occurred_on" => on,
          "arrival_on" => Date.to_iso8601(arrival),
          "departure_on" => arrival |> Date.add(3) |> Date.to_iso8601()
        }),
        op("record_cash_payment", "source-#{source}", on, %{"amount_cents" => amount}),
        op("cancel_group", "source-#{source}", on, %{
          "operation_id" => source,
          "refund_method" => "hotel_credit"
        })
      ])

    assert result["status"] == "applied"
    result
  end

  defp op(type, group_id, on, attrs \\ %{}) do
    operation(type, Map.merge(%{"group_id" => group_id, "occurred_on" => on}, attrs))
  end

  defp reject_unchanged(conn, operation, code) do
    before = snapshot()
    assert [%{"status" => "rejected", "code" => ^code}] = batch(conn, [operation])
    assert snapshot() == before
  end

  defp snapshot,
    do: {Repo.all(Group), Repo.all(Room), Repo.all(CreditLot), Repo.all(CreditAllocation)}

  defp batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_data(conn, path),
    do: conn |> recycle() |> get(path) |> json_response(200) |> Map.fetch!("data")

  defp group(conn, id), do: get_data(conn, "/api/v1/groups/#{URI.encode(id)}")

  defp credit(conn, guest, on),
    do: get_data(conn, "/api/v1/guests/#{URI.encode(guest)}/credit?on=#{on}")

  defp ledger(conn, on), do: get_data(conn, "/api/v1/ledger?on=#{on}")
end
