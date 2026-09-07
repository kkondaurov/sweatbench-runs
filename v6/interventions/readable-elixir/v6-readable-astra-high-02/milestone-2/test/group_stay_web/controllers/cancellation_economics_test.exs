defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group, Room}

  for {booked_on, policy, deadline} <- [
        {"2026-12-31", "flex-14", "2027-02-15"},
        {"2027-01-01", "flex-30", "2027-01-30"}
      ] do
    test "booking on #{booked_on} fixes #{policy} with an inclusive deadline", %{conn: conn} do
      for {offset, refundable?} <- [{-1, true}, {0, true}, {1, false}] do
        id = "group-#{offset}"

        batch(conn, [
          open_group(%{
            "group_id" => id,
            "occurred_on" => unquote(booked_on),
            "arrival_on" => "2027-03-01",
            "departure_on" => "2027-03-04"
          })
        ])

        assert %{"policy_version" => unquote(policy), "refundable_until" => unquote(deadline)} =
                 group(conn, id)

        [_, result] =
          batch(conn, [
            op("record_cash_payment", id, %{"amount_cents" => 100}),
            op("cancel_group", id, %{
              "occurred_on" =>
                Date.to_iso8601(Date.add(Date.from_iso8601!(unquote(deadline)), offset))
            })
          ])

        assert result["refunded_cents"] == if(refundable?, do: 100, else: 0)
        assert result["retained_cents"] == if(refundable?, do: 0, else: 100)
      end
    end
  end

  test "rescheduling keeps each policy and recomputes its deadline", %{conn: conn} do
    for {plan, booked, policy, deadline} <- [
          {"flexible", "2026-12-31", "flex-14", "2028-02-15"},
          {"flexible", "2027-01-01", "flex-30", "2028-01-30"},
          {"advance_purchase", "2027-01-01", "advance-nonrefundable", nil}
        ] do
      batch(conn, [
        open_group(%{"group_id" => policy, "rate_plan" => plan, "occurred_on" => booked})
      ])

      [result] =
        batch(conn, [
          op("reschedule_group", policy, %{
            "occurred_on" => "2027-02-01",
            "new_arrival_on" => "2028-02-29",
            "expected_revision" => 1
          })
        ])

      assert result["policy_version"] == policy
      assert result["refundable_until"] == deadline
      assert result["new_departure_on"] == "2028-03-03"
      assert result["revision"] == 2
      saved = group(conn, policy)
      assert saved["policy_version"] == policy
      assert saved["refundable_until"] == deadline
    end
  end

  test "conversion rounds the bonus half upward and expiry is inclusive", %{conn: conn} do
    result = issue(conn, "source", "cancel-17", 5005, "2027-05-03")

    assert result == %{
             "operation_id" => "cancel-17",
             "status" => "applied",
             "group_id" => "source",
             "revision" => 3,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 5506
           }

    assert credit(conn, "2028-05-02") == %{
             "guest_id" => "guest-22",
             "available_cents" => 5506,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 5506,
                 "expires_on" => "2028-05-02"
               }
             ]
           }

    assert ledger(conn, "2028-05-02") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 5005,
             "credit_liability_cents" => 5506
           }

    before = snapshot()
    assert credit(conn, "2028-05-03")["available_cents"] == 0
    assert credit(conn, "2028-05-03")["lots"] == []
    assert ledger(conn, "2028-05-03")["credit_liability_cents"] == 0
    assert ledger(conn, "2028-05-03")["cash_converted_to_credit_cents"] == 5005
    assert snapshot() == before
    assert credit(conn, "2028-05-02")["available_cents"] == 5506
  end

  test "cash conversion and credit redemption observe earlier operations in one batch", %{
    conn: conn
  } do
    results =
      batch(conn, [
        open_group(),
        operation("record_cash_payment", %{"amount_cents" => 100}),
        operation("cancel_group", %{"refund_method" => "hotel_credit", "expected_revision" => 2}),
        open_group(%{"group_id" => "next"}),
        op("apply_hotel_credit", "next", %{"amount_cents" => 60, "expected_revision" => 1}),
        op("apply_hotel_credit", "next", %{"amount_cents" => 51, "expected_revision" => 2}),
        op("apply_hotel_credit", "next", %{"amount_cents" => 50, "expected_revision" => 2})
      ])

    assert Enum.map(results, & &1["status"]) ==
             ~w(applied applied applied applied applied rejected applied)

    assert Enum.at(results, 5)["code"] == "insufficient_credit"

    assert List.last(results) == %{
             "operation_id" => "apply_hotel_credit-1",
             "status" => "applied",
             "group_id" => "next",
             "amount_cents" => 50,
             "outstanding_deposit_cents" => 19390,
             "revision" => 3
           }

    assert group(conn, "next")["deposit_paid_cents"] == 110
    assert group(conn, "next")["credit_paid_cents"] == 110
    assert group(conn, "next")["cash_paid_cents"] == 0
    assert credit(conn, "2026-11-01")["lots"] == []
    assert ledger(conn, "2028-01-01")["credit_liability_cents"] == 110
    assert ledger(conn, "2026-11-01")["cash_held_cents"] == 0
    assert Repo.aggregate(CreditAllocation, :count) == 1
  end

  test "lots are consumed by expiry then source identifier and restored to the same lots", %{
    conn: conn
  } do
    issue(conn, "later", "a-later", 100, "2027-01-02")
    issue(conn, "z", "z-source", 100, "2027-01-01")
    issue(conn, "a", "a-source", 100, "2027-01-01")

    assert Enum.map(credit(conn, "2027-02-01")["lots"], & &1["source_operation_id"]) ==
             ["a-source", "z-source", "a-later"]

    batch(conn, [
      open_group(%{
        "group_id" => "next",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      })
    ])

    batch(conn, [
      op("apply_hotel_credit", "next", %{"amount_cents" => 150, "occurred_on" => "2027-02-01"})
    ])

    assert Enum.map(
             credit(conn, "2027-02-01")["lots"],
             &{&1["source_operation_id"], &1["remaining_cents"]}
           ) ==
             [{"z-source", 70}, {"a-later", 110}]

    assert ledger(conn, "2027-02-01")["credit_liability_cents"] == 330

    [result] =
      batch(conn, [
        op("cancel_group", "next", %{
          "occurred_on" => "2027-03-01",
          "refund_method" => "hotel_credit"
        })
      ])

    assert result["credit_issued_cents"] == 0
    assert result["refunded_cents"] == 0

    assert Enum.map(credit(conn, "2027-03-01")["lots"], & &1["remaining_cents"]) == [
             110,
             110,
             110
           ]

    assert Repo.aggregate(CreditLot, :count) == 3
    assert Repo.aggregate(CreditAllocation, :count) == 0
    assert ledger(conn, "2027-03-01")["credit_liability_cents"] == 330
  end

  for method <- ["cash", "hotel_credit"] do
    test "mixed funding settles cash via #{method} and restores credit without another bonus", %{
      conn: conn
    } do
      issue(conn, "source", "original", 100, "2027-01-01")

      batch(conn, [
        open_group(%{
          "group_id" => "next",
          "arrival_on" => "2028-06-01",
          "departure_on" => "2028-06-04"
        })
      ])

      batch(conn, [
        op("apply_hotel_credit", "next", %{"amount_cents" => 80, "occurred_on" => "2027-02-01"}),
        op("record_cash_payment", "next", %{"amount_cents" => 55})
      ])

      assert %{"deposit_paid_cents" => 135, "cash_paid_cents" => 55, "credit_paid_cents" => 80} =
               group(conn, "next")

      assert ledger(conn, "2027-02-01")["cash_held_cents"] == 55

      [result] =
        batch(conn, [
          op("cancel_group", "next", %{
            "refund_method" => unquote(method),
            "operation_id" => "mixed-cancel",
            "occurred_on" => "2027-03-01"
          })
        ])

      issued = if unquote(method) == "hotel_credit", do: 61, else: 0
      assert result["credit_issued_cents"] == issued
      assert result["refunded_cents"] == if(unquote(method) == "cash", do: 55, else: 0)
      assert result["retained_cents"] == 0
      assert credit(conn, "2027-03-01")["available_cents"] == 110 + issued
      assert hd(credit(conn, "2027-03-01")["lots"])["source_operation_id"] == "original"
      assert hd(credit(conn, "2027-03-01")["lots"])["remaining_cents"] == 110
      assert ledger(conn, "2027-03-01")["credit_liability_cents"] == 110 + issued

      assert ledger(conn, "2027-03-01")["cash_converted_to_credit_cents"] ==
               if(issued > 0, do: 155, else: 100)

      assert %{"deposit_paid_cents" => 0, "cash_paid_cents" => 0, "credit_paid_cents" => 0} =
               group(conn, "next")
    end
  end

  test "expiry pauses while allocated and expired restoration reduces liability immediately", %{
    conn: conn
  } do
    issue(conn, "early", "early", 100, "2027-01-01")
    issue(conn, "late", "late", 100, "2027-06-01")

    batch(conn, [
      open_group(%{
        "group_id" => "next",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      })
    ])

    batch(conn, [
      op("apply_hotel_credit", "next", %{"amount_cents" => 150, "occurred_on" => "2027-12-01"})
    ])

    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 220
    assert credit(conn, "2028-01-02")["available_cents"] == 70
    batch(conn, [op("cancel_group", "next", %{"occurred_on" => "2028-01-02"})])
    assert credit(conn, "2028-01-02")["available_cents"] == 110
    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 110
    assert ledger(conn, "2028-06-01")["credit_liability_cents"] == 0
    assert Repo.aggregate(CreditAllocation, :count) == 0
  end

  test "credit can be redeemed and restored on its expiry date", %{conn: conn} do
    issue(conn, "source", "original", 100, "2027-01-01")

    batch(conn, [
      open_group(%{
        "group_id" => "next",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      })
    ])

    [applied, cancelled] =
      batch(conn, [
        op("apply_hotel_credit", "next", %{"amount_cents" => 110, "occurred_on" => "2028-01-01"}),
        op("cancel_group", "next", %{"occurred_on" => "2028-01-01"})
      ])

    assert applied["status"] == "applied"
    assert cancelled["status"] == "applied"
    assert credit(conn, "2028-01-01")["available_cents"] == 110
    assert credit(conn, "2028-01-02")["available_cents"] == 0
  end

  for plan <- ["flexible", "advance_purchase"] do
    test "non-refundable #{plan} cancellation retains cash and consumes credit", %{conn: conn} do
      issue(conn, "source", "original", 100, "2027-01-01")

      batch(conn, [
        open_group(%{
          "group_id" => "next",
          "rate_plan" => unquote(plan),
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })
      ])

      batch(conn, [
        op("apply_hotel_credit", "next", %{"amount_cents" => 80, "occurred_on" => "2027-02-01"}),
        op("record_cash_payment", "next", %{"amount_cents" => 50})
      ])

      before = snapshot()

      [rejected] =
        batch(conn, [
          op("cancel_group", "next", %{
            "occurred_on" => "2027-05-31",
            "refund_method" => "hotel_credit",
            "expected_revision" => 3
          })
        ])

      assert rejected["code"] == "refund_method_not_available"
      assert snapshot() == before

      [result] =
        batch(conn, [
          op("cancel_group", "next", %{"occurred_on" => "2027-05-31", "expected_revision" => 3})
        ])

      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 50,
               "credit_issued_cents" => 0,
               "revision" => 4
             } = result

      assert credit(conn, "2027-05-31")["available_cents"] == 30
      assert ledger(conn, "2027-05-31")["credit_liability_cents"] == 30
      assert ledger(conn, "2027-05-31")["cash_retained_cents"] == 50
    end
  end

  test "credit validation rejects atomically, honors revision precedence and isolates guests", %{
    conn: conn
  } do
    issue(conn, "source", "original", 100, "2027-01-01")

    batch(conn, [
      open_group(%{"group_id" => "next"}),
      open_group(%{"group_id" => "other", "guest_id" => "other-guest"})
    ])

    before = snapshot()

    for amount <- [nil, 0, -1, 1.5, "1", true, [], %{}, 9_223_372_036_854_775_808] do
      assert [%{"code" => "invalid_amount"}] =
               batch(conn, [op("apply_hotel_credit", "next", %{"amount_cents" => amount})])

      assert snapshot() == before
    end

    for {id, amount, date, code} <- [
          {"missing", 1, "2027-02-01", "group_not_found"},
          {"source", 1, "2027-02-01", "group_not_active"},
          {"next", 20000, "2027-02-01", "payment_exceeds_outstanding"},
          {"next", 111, "2027-02-01", "insufficient_credit"},
          {"next", 1, "2028-01-02", "insufficient_credit"},
          {"other", 1, "2027-02-01", "insufficient_credit"}
        ] do
      assert [%{"code" => ^code}] =
               batch(conn, [
                 op("apply_hotel_credit", id, %{"amount_cents" => amount, "occurred_on" => date})
               ])

      assert snapshot() == before
    end

    for command <- [
          op("apply_hotel_credit", "next", %{"amount_cents" => 111}),
          op("cancel_group", "next", %{
            "refund_method" => "hotel_credit",
            "occurred_on" => "2026-12-09"
          }),
          op("cancel_group", "next", %{"refund_method" => "unknown"})
        ] do
      assert [%{"code" => "stale_revision", "actual_revision" => 1, "expected_revision" => 2}] =
               batch(conn, [Map.put(command, "expected_revision", 2)])

      assert snapshot() == before
    end

    for method <- [nil, "unknown", 12, %{}, []] do
      assert [%{"code" => "invalid_operation"}] =
               batch(conn, [op("cancel_group", "next", %{"refund_method" => method})])

      assert snapshot() == before
    end

    assert [%{"code" => "invalid_operation"}] =
             batch(conn, [op("apply_hotel_credit", "next", %{})])

    assert snapshot() == before
  end

  test "credit reads use UTC today by default, preserve guest identifiers and reject invalid dates",
       %{conn: conn} do
    today = Date.utc_today()
    issue(conn, "expired", "expired", 100, Date.to_iso8601(Date.add(today, -366)))
    issue(conn, "current", "current", 100, Date.to_iso8601(today))

    assert conn
           |> get("/api/v1/guests/guest-22/credit")
           |> json_response(200)
           |> Map.fetch!("data") == credit(conn, Date.to_iso8601(today))

    assert credit(conn, Date.to_iso8601(today))["available_cents"] == 110

    assert conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data") ==
             ledger(conn, Date.to_iso8601(today))

    assert conn |> get("/api/v1/guests/Unknown%20Guest/credit") |> json_response(200) == %{
             "data" => %{"guest_id" => "Unknown Guest", "available_cents" => 0, "lots" => []}
           }

    for path <- ["/api/v1/ledger", "/api/v1/guests/guest-22/credit"],
        date <- ["bad", "2027-02-29", "", "2028-13-01"] do
      assert conn |> get(path, %{"on" => date}) |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end

  test "zero-cash credit cancellation creates no empty lot", %{conn: conn} do
    [_, result] =
      batch(conn, [open_group(), operation("cancel_group", %{"refund_method" => "hotel_credit"})])

    assert result["credit_issued_cents"] == 0
    assert Repo.all(CreditLot) == []
  end

  defp issue(conn, group_id, source_id, cash, date) do
    arrival = date |> Date.from_iso8601!() |> Date.add(60)

    [_, _, result] =
      batch(conn, [
        open_group(%{
          "group_id" => group_id,
          "occurred_on" => date,
          "arrival_on" => Date.to_iso8601(arrival),
          "departure_on" => Date.to_iso8601(Date.add(arrival, 3))
        }),
        op("record_cash_payment", group_id, %{"amount_cents" => cash, "occurred_on" => date}),
        op("cancel_group", group_id, %{
          "operation_id" => source_id,
          "occurred_on" => date,
          "refund_method" => "hotel_credit"
        })
      ])

    assert result["status"] == "applied"
    result
  end

  defp op(type, id, fields), do: operation(type, Map.put(fields, "group_id", id))

  defp batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn, id),
    do: conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp credit(conn, date),
    do:
      conn
      |> get("/api/v1/guests/guest-22/credit", %{"on" => date})
      |> json_response(200)
      |> Map.fetch!("data")

  defp ledger(conn, date),
    do: conn |> get("/api/v1/ledger", %{"on" => date}) |> json_response(200) |> Map.fetch!("data")

  defp snapshot,
    do: {Repo.all(Group), Repo.all(Room), Repo.all(CreditLot), Repo.all(CreditAllocation)}
end
