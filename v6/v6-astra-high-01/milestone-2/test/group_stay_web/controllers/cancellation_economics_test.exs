defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{CreditAllocation, CreditLot, Group, Repo}

  defp opening(id, fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{id}",
        "type" => "open_group",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 50000}]
      },
      fields
    )
  end

  defp operation(type, id, fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "#{type}-#{id}",
        "type" => type,
        "group_id" => id,
        "occurred_on" => "2027-01-30"
      },
      fields
    )
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(conn, path, params \\ %{}),
    do: conn |> get(path, params) |> json_response(200) |> Map.fetch!("data")

  defp credit(conn, on \\ "2027-01-30", guest \\ "guest"),
    do: read(conn, ~p"/api/v1/guests/#{guest}/credit", %{"on" => on})

  defp ledger(conn, on \\ "2027-01-30"),
    do: read(conn, ~p"/api/v1/ledger", %{"on" => on})

  defp issue(conn, id, amount, on \\ "2027-01-30", guest \\ "guest") do
    date = Date.from_iso8601!(on)

    results =
      submit(conn, [
        opening(id, %{
          "guest_id" => guest,
          "occurred_on" => on,
          "arrival_on" => Date.to_iso8601(Date.add(date, 60)),
          "departure_on" => Date.to_iso8601(Date.add(date, 61))
        }),
        operation("record_cash_payment", id, %{"amount_cents" => amount, "occurred_on" => on}),
        operation("cancel_group", id, %{
          "operation_id" => id,
          "refund_method" => "hotel_credit",
          "occurred_on" => on
        })
      ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    List.last(results)
  end

  defp snapshot do
    for schema <- [Group, CreditLot, CreditAllocation], do: Repo.all(schema)
  end

  defp rejected(conn, operation, code) do
    before = snapshot()
    assert [%{"status" => "rejected", "code" => ^code}] = submit(conn, [operation])
    assert snapshot() == before
  end

  test "booking date selects fixed policy and cancellation includes the deadline", %{conn: conn} do
    for {booked, policy, deadline} <- [
          {"2026-12-31", "flex-14", "2027-02-15"},
          {"2027-01-01", "flex-30", "2027-01-30"}
        ],
        days_late <- [0, 1] do
      id = "#{policy}-#{days_late}"
      date = deadline |> Date.from_iso8601!() |> Date.add(days_late) |> Date.to_iso8601()
      submit(conn, [opening(id, %{"occurred_on" => booked})])
      group = read(conn, ~p"/api/v1/groups/#{id}")
      assert group["policy_version"] == policy
      assert group["refundable_until"] == deadline
      submit(conn, [operation("record_cash_payment", id, %{"amount_cents" => 100})])
      [result] = submit(conn, [operation("cancel_group", id, %{"occurred_on" => date})])
      assert result["refunded_cents"] == if(days_late == 0, do: 100, else: 0)
      assert result["retained_cents"] == if(days_late == 0, do: 0, else: 100)
      assert result["credit_issued_cents"] == 0
      assert result["revision"] == 3
    end
  end

  test "reschedule keeps every policy and recomputes the deadline across leap day", %{conn: conn} do
    for {id, booked, plan, deadline} <- [
          {"flex-14", "2026-12-31", "flexible", "2028-02-16"},
          {"flex-30", "2027-01-01", "flexible", "2028-01-31"},
          {"advance-nonrefundable", "2027-01-01", "advance_purchase", nil}
        ] do
      submit(conn, [opening(id, %{"occurred_on" => booked, "rate_plan" => plan})])

      assert [
               %{
                 "policy_version" => ^id,
                 "refundable_until" => ^deadline,
                 "new_departure_on" => "2028-03-02",
                 "revision" => 2
               }
             ] =
               submit(conn, [
                 operation("reschedule_group", id, %{
                   "occurred_on" => "2028-01-01",
                   "new_arrival_on" => "2028-03-01"
                 })
               ])

      group = read(conn, ~p"/api/v1/groups/#{id}")
      assert group["policy_version"] == id
      assert group["refundable_until"] == deadline
    end
  end

  test "credit conversion rounds the bonus half upward and separates cash totals", %{conn: conn} do
    for {id, cash, issued} <- [{"a", 4, 4}, {"b", 5, 6}, {"c", 15, 17}, {"d", 5000, 5500}] do
      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => ^issued,
               "revision" => 3
             } = issue(conn, id, cash)
    end

    assert credit(conn) == %{
             "guest_id" => "guest",
             "available_cents" => 5527,
             "lots" =>
               for(
                 {id, amount} <- [{"a", 4}, {"b", 6}, {"c", 17}, {"d", 5500}],
                 do: %{
                   "source_operation_id" => id,
                   "remaining_cents" => amount,
                   "expires_on" => "2028-01-30"
                 }
               )
           }

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 5024,
             "credit_liability_cents" => 5527
           }

    submit(conn, [opening("unfunded")])

    assert [%{"credit_issued_cents" => 0}] =
             submit(conn, [
               operation("cancel_group", "unfunded", %{"refund_method" => "hotel_credit"})
             ])

    assert length(credit(conn)["lots"]) == 4
  end

  test "lots expire the day after day 365 and reads cannot expire them destructively", %{
    conn: conn
  } do
    issue(conn, "source", 100, "2027-03-01")
    assert credit(conn, "2028-02-29")["available_cents"] == 110
    assert ledger(conn, "2028-02-29")["credit_liability_cents"] == 110
    before = snapshot()
    assert credit(conn, "2028-03-01")["lots"] == []
    assert ledger(conn, "2028-03-01")["credit_liability_cents"] == 0
    assert snapshot() == before
    submit(conn, [opening("target")])

    rejected(
      conn,
      operation("apply_hotel_credit", "target", %{
        "amount_cents" => 1,
        "occurred_on" => "2028-03-01"
      }),
      "insufficient_credit"
    )

    assert [%{"amount_cents" => 110, "revision" => 2}] =
             submit(conn, [
               operation("apply_hotel_credit", "target", %{
                 "amount_cents" => 110,
                 "occurred_on" => "2028-02-29"
               })
             ])

    assert ledger(conn, "2028-03-01")["credit_liability_cents"] == 110
  end

  test "allocation orders by expiry then identifier and restores repeated partial uses", %{
    conn: conn
  } do
    issue(conn, "b", 100, "2027-01-02")
    issue(conn, "z", 100, "2027-01-01")
    issue(conn, "a", 100, "2027-01-02")
    issue(conn, "other", 100, "2027-01-01", "someone-else")
    assert Enum.map(credit(conn)["lots"], & &1["source_operation_id"]) == ~w(z a b)
    submit(conn, [opening("target")])
    submit(conn, [operation("apply_hotel_credit", "target", %{"amount_cents" => 150})])

    assert Enum.map(credit(conn)["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) ==
             [{"a", 70}, {"b", 110}]

    submit(conn, [operation("apply_hotel_credit", "target", %{"amount_cents" => 100})])
    assert [%{"source_operation_id" => "b", "remaining_cents" => 80}] = credit(conn)["lots"]
    assert ledger(conn)["credit_liability_cents"] == 440

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0, "revision" => 4}] =
             submit(conn, [operation("cancel_group", "target")])

    assert Enum.map(credit(conn)["lots"], & &1["remaining_cents"]) == [110, 110, 110]
    assert Repo.all(CreditAllocation) == []
    assert credit(conn, "2027-01-30", "someone-else")["available_cents"] == 110
  end

  test "refundable mixed funding restores original credit and only bonuses new cash", %{
    conn: conn
  } do
    for method <- ~w(cash hotel_credit) do
      guest = method
      issue(conn, "source-#{method}", 100, "2027-01-01", guest)

      submit(conn, [
        opening(method, %{"guest_id" => guest}),
        operation("apply_hotel_credit", method, %{"amount_cents" => 100}),
        operation("record_cash_payment", method, %{"amount_cents" => 50})
      ])

      group = read(conn, ~p"/api/v1/groups/#{method}")

      assert Map.take(
               group,
               ~w(cash_paid_cents credit_paid_cents deposit_paid_cents outstanding_deposit_cents revision)
             ) == %{
               "cash_paid_cents" => 50,
               "credit_paid_cents" => 100,
               "deposit_paid_cents" => 150,
               "outstanding_deposit_cents" => 9850,
               "revision" => 3
             }

      [result] = submit(conn, [operation("cancel_group", method, %{"refund_method" => method})])
      assert result["credit_issued_cents"] == if(method == "cash", do: 0, else: 55)
      assert result["refunded_cents"] == if(method == "cash", do: 50, else: 0)
      assert result["retained_cents"] == 0
      assert result["revision"] == 4

      assert credit(conn, "2027-01-30", guest)["available_cents"] ==
               if(method == "cash", do: 110, else: 165)

      assert Enum.find(
               credit(conn, "2027-01-30", guest)["lots"],
               &(&1["source_operation_id"] == "source-#{method}")
             ) == %{
               "source_operation_id" => "source-#{method}",
               "remaining_cents" => 110,
               "expires_on" => "2028-01-01"
             }

      cancelled = read(conn, ~p"/api/v1/groups/#{method}")

      for field <-
            ~w(cash_paid_cents credit_paid_cents deposit_paid_cents deposit_due_cents outstanding_deposit_cents),
          do: assert(cancelled[field] == 0)
    end

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 50,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 250,
             "credit_liability_cents" => 275
           }
  end

  test "active allocations pause expiry and restoration on or after expiry settles correctly", %{
    conn: conn
  } do
    for {id, cancelled_on, available} <- [
          {"boundary", "2028-01-01", 110},
          {"expired", "2028-01-02", 0}
        ] do
      issue(conn, "source-#{id}", 100, "2027-01-01", id)

      submit(conn, [
        opening(id, %{
          "guest_id" => id,
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-02"
        }),
        operation("apply_hotel_credit", id, %{"amount_cents" => 100})
      ])

      assert credit(conn, "2028-01-02", id)["available_cents"] == 0
      liability_before = ledger(conn, cancelled_on)["credit_liability_cents"]

      submit(conn, [
        operation("cancel_group", id, %{
          "occurred_on" => cancelled_on,
          "refund_method" => "hotel_credit"
        })
      ])

      assert credit(conn, cancelled_on, id)["available_cents"] == available

      assert ledger(conn, cancelled_on)["credit_liability_cents"] ==
               liability_before - if(available == 0, do: 100, else: 0)
    end
  end

  test "nonrefundable cash is retained and redeemed credit is consumed", %{conn: conn} do
    for {id, plan, date} <- [
          {"late", "flexible", "2027-01-31"},
          {"advance", "advance_purchase", "2027-01-01"}
        ] do
      issue(conn, "source-#{id}", 100, "2027-01-01", id)

      submit(conn, [
        opening(id, %{"guest_id" => id, "rate_plan" => plan}),
        operation("apply_hotel_credit", id, %{"amount_cents" => 100}),
        operation("record_cash_payment", id, %{"amount_cents" => 50})
      ])

      cancel =
        operation("cancel_group", id, %{"occurred_on" => date, "refund_method" => "hotel_credit"})

      rejected(conn, Map.put(cancel, "expected_revision", 2), "stale_revision")
      rejected(conn, Map.put(cancel, "expected_revision", 3), "refund_method_not_available")

      assert [
               %{
                 "retained_cents" => 50,
                 "refunded_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] = submit(conn, [Map.put(cancel, "refund_method", "cash")])

      assert credit(conn, "2027-01-30", id)["available_cents"] == 10
    end

    assert ledger(conn)["cash_retained_cents"] == 100
    assert ledger(conn)["credit_liability_cents"] == 20
    assert Repo.all(CreditAllocation) == []
  end

  test "rescheduled mixed funding restores only live lots and restored credit can be reused", %{
    conn: conn
  } do
    issue(conn, "early", 100, "2027-01-01")
    issue(conn, "later", 100, "2027-06-01")

    results =
      submit(conn, [
        opening("target"),
        operation("apply_hotel_credit", "target", %{
          "amount_cents" => 150,
          "occurred_on" => "2027-06-01"
        }),
        operation("record_cash_payment", "target", %{"amount_cents" => 5}),
        operation("reschedule_group", "target", %{
          "new_arrival_on" => "2028-03-01",
          "occurred_on" => "2027-06-01"
        })
      ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    group = read(conn, ~p"/api/v1/groups/target")
    assert group["cash_paid_cents"] == 5
    assert group["credit_paid_cents"] == 150
    assert group["deposit_paid_cents"] == 155
    assert group["refundable_until"] == "2028-01-31"
    assert ledger(conn, "2028-01-02")["cash_held_cents"] == 5
    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 220

    assert [%{"credit_issued_cents" => 6, "revision" => 5}] =
             submit(conn, [
               operation("cancel_group", "target", %{
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2028-01-02"
               })
             ])

    assert credit(conn, "2028-01-02")["lots"] == [
             %{
               "source_operation_id" => "later",
               "remaining_cents" => 110,
               "expires_on" => "2028-05-31"
             },
             %{
               "source_operation_id" => "cancel_group-target",
               "remaining_cents" => 6,
               "expires_on" => "2029-01-01"
             }
           ]

    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 116

    results =
      submit(conn, [
        opening("reuse", %{"arrival_on" => "2028-03-01", "departure_on" => "2028-03-02"}),
        operation("apply_hotel_credit", "reuse", %{
          "amount_cents" => 110,
          "occurred_on" => "2028-01-02"
        }),
        operation("cancel_group", "reuse", %{
          "refund_method" => "hotel_credit",
          "occurred_on" => "2028-01-02"
        })
      ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert List.last(results)["credit_issued_cents"] == 0
    assert credit(conn, "2028-01-02")["available_cents"] == 116
    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 116
  end

  test "credit validation and rejected methods preserve every accounting table", %{conn: conn} do
    issue(conn, "source", 100)
    submit(conn, [opening("target"), opening("other", %{"guest_id" => "other"})])
    apply = operation("apply_hotel_credit", "target", %{"amount_cents" => 111})
    rejected(conn, Map.put(apply, "expected_revision", 0), "stale_revision")
    rejected(conn, apply, "insufficient_credit")
    rejected(conn, Map.put(apply, "group_id", "missing"), "group_not_found")

    rejected(
      conn,
      Map.merge(apply, %{"group_id" => "other", "amount_cents" => 1}),
      "insufficient_credit"
    )

    rejected(conn, Map.put(apply, "amount_cents", 10001), "payment_exceeds_outstanding")
    rejected(conn, Map.delete(apply, "amount_cents"), "invalid_operation")

    for amount <- [0, -1, nil, "10", 1.0, true, []],
        do: rejected(conn, Map.put(apply, "amount_cents", amount), "invalid_amount")

    for method <- [nil, "unknown", 1, %{}] do
      cancel = operation("cancel_group", "target", %{"refund_method" => method})
      rejected(conn, Map.put(cancel, "expected_revision", 0), "stale_revision")
      rejected(conn, cancel, "invalid_operation")
    end

    submit(conn, [operation("cancel_group", "target")])
    rejected(conn, Map.put(apply, "amount_cents", 1), "group_not_active")
  end

  test "ordered batches see new credit and revisions and continue after rejection", %{conn: conn} do
    results =
      submit(conn, [
        opening("source"),
        opening("target"),
        operation("record_cash_payment", "source", %{"amount_cents" => 100}),
        operation("cancel_group", "source", %{"refund_method" => "hotel_credit"}),
        operation("apply_hotel_credit", "target", %{
          "amount_cents" => 111,
          "expected_revision" => 1
        }),
        operation("apply_hotel_credit", "target", %{
          "amount_cents" => 100,
          "expected_revision" => 1
        }),
        operation("apply_hotel_credit", "target", %{
          "amount_cents" => 10,
          "expected_revision" => 1
        }),
        operation("apply_hotel_credit", "target", %{
          "amount_cents" => 10,
          "expected_revision" => 2
        })
      ])

    assert Enum.map(results, & &1["status"]) ==
             ~w(applied applied applied applied rejected applied rejected applied)

    assert Enum.at(results, 4)["code"] == "insufficient_credit"
    assert Enum.at(results, 6)["code"] == "stale_revision"
    assert List.last(results)["revision"] == 3
    assert credit(conn)["available_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 110
  end

  test "credit reads support empty guests, UTC defaults, and invalid date responses", %{
    conn: conn
  } do
    assert credit(conn, "2027-01-30", " Guest Ω ") == %{
             "guest_id" => " Guest Ω ",
             "available_cents" => 0,
             "lots" => []
           }

    today = Date.utc_today()
    issue(conn, "expired", 100, today |> Date.add(-366) |> Date.to_iso8601())
    issue(conn, "valid", 100, today |> Date.add(-365) |> Date.to_iso8601())
    assert read(conn, ~p"/api/v1/guests/guest/credit")["available_cents"] == 110
    assert read(conn, ~p"/api/v1/ledger")["credit_liability_cents"] == 110

    for path <- [~p"/api/v1/ledger", ~p"/api/v1/guests/guest/credit"],
        on <- ["bad", "2027-02-29", "", ["2027-01-01"]] do
      assert conn |> get(path, %{"on" => on}) |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end
end
