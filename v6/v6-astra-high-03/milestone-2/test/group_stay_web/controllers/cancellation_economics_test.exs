defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{CreditAllocation, CreditLot, Group, Repo}

  defp open(id, changes \\ %{}) do
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
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100_000}]
      },
      changes
    )
  end

  defp op(type, id, changes \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "#{type}-#{id}",
        "type" => type,
        "group_id" => id,
        "occurred_on" => "2027-05-02"
      },
      changes
    )
  end

  defp batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(conn, path),
    do: conn |> get("/api/v1/#{path}") |> json_response(200) |> Map.fetch!("data")

  defp credit(conn, on \\ "2027-05-02"), do: read(conn, "guests/guest/credit?on=#{on}")
  defp ledger(conn, on \\ "2027-05-02"), do: read(conn, "ledger?on=#{on}")

  defp issue(conn, id, amount, date \\ "2027-05-02", operation_id \\ nil) do
    results =
      batch(conn, [
        open(id),
        op("record_cash_payment", id, %{"amount_cents" => amount}),
        op("cancel_group", id, %{
          "occurred_on" => date,
          "refund_method" => "hotel_credit",
          "operation_id" => operation_id || "cancel-#{id}"
        })
      ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    List.last(results)
  end

  defp snapshot do
    {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation)}
  end

  test "booking date fixes policy and rescheduling recomputes its inclusive deadline", %{
    conn: conn
  } do
    for {id, booked, plan, policy, until} <- [
          {"old", "2026-12-31", "flexible", "flex-14", "2027-05-18"},
          {"new", "2027-01-01", "flexible", "flex-30", "2027-05-02"},
          {"advance", "2026-12-31", "advance_purchase", "advance-nonrefundable", nil}
        ] do
      batch(conn, [open(id, %{"occurred_on" => booked, "rate_plan" => plan})])
      group = read(conn, "groups/#{id}")
      assert group["policy_version"] == policy
      assert group["refundable_until"] == until

      assert [
               %{
                 "policy_version" => ^policy,
                 "refundable_until" => moved_until,
                 "new_departure_on" => "2028-03-02",
                 "revision" => 2
               }
             ] =
               batch(conn, [
                 op("reschedule_group", id, %{
                   "occurred_on" => "2027-12-01",
                   "new_arrival_on" => "2028-03-01"
                 })
               ])

      expected_until =
        case policy do
          "flex-14" -> "2028-02-16"
          "flex-30" -> "2028-01-31"
          _ -> nil
        end

      assert moved_until == expected_until
      assert read(conn, "groups/#{id}")["refundable_until"] == moved_until
    end
  end

  test "new policy refunds on day 30 and retains on day 29", %{conn: conn} do
    for {id, on, refund, retain} <- [
          {"boundary", "2027-05-02", 123, 0},
          {"late", "2027-05-03", 0, 123}
        ] do
      assert [
               _,
               _,
               %{
                 "refunded_cents" => ^refund,
                 "retained_cents" => ^retain,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] =
               batch(conn, [
                 open(id),
                 op("record_cash_payment", id, %{"amount_cents" => 123}),
                 op("cancel_group", id, %{"occurred_on" => on})
               ])
    end
  end

  test "credit bonus rounds half upward and conversion moves cash to its own ledger total", %{
    conn: conn
  } do
    assert %{
             "credit_issued_cents" => 6,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "revision" => 3
           } = issue(conn, "half", 5)

    assert %{"credit_issued_cents" => 4} = issue(conn, "down", 4)
    assert %{"credit_issued_cents" => 7} = issue(conn, "up", 6)

    assert credit(conn) == %{
             "guest_id" => "guest",
             "available_cents" => 17,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-down",
                 "remaining_cents" => 4,
                 "expires_on" => "2028-05-01"
               },
               %{
                 "source_operation_id" => "cancel-half",
                 "remaining_cents" => 6,
                 "expires_on" => "2028-05-01"
               },
               %{
                 "source_operation_id" => "cancel-up",
                 "remaining_cents" => 7,
                 "expires_on" => "2028-05-01"
               }
             ]
           }

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 15,
             "credit_liability_cents" => 17
           }

    assert %{"cash_paid_cents" => 0, "credit_paid_cents" => 0, "deposit_paid_cents" => 0} =
             read(conn, "groups/half")
  end

  test "nonrefundable and malformed methods reject atomically after the revision check", %{
    conn: conn
  } do
    for {id, changes, date} <- [
          {"late", %{}, "2027-05-03"},
          {"advance", %{"rate_plan" => "advance_purchase"}, "2027-05-02"}
        ] do
      batch(conn, [open(id, changes), op("record_cash_payment", id, %{"amount_cents" => 100})])
      before = snapshot()
      cancel = op("cancel_group", id, %{"occurred_on" => date, "refund_method" => "hotel_credit"})

      assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
               batch(conn, [Map.put(cancel, "expected_revision", 1)])

      assert [%{"code" => "refund_method_not_available"}] =
               batch(conn, [Map.put(cancel, "expected_revision", 2)])

      for method <- ["unknown", nil, 12, %{}] do
        assert [%{"code" => "invalid_operation"}] =
                 batch(conn, [Map.put(cancel, "refund_method", method)])
      end

      assert snapshot() == before

      assert [%{"retained_cents" => 100, "revision" => 3}] =
               batch(conn, [Map.put(cancel, "refund_method", "cash")])
    end
  end

  test "lots are consumed by expiry then source identifier and restored without a second bonus",
       %{conn: conn} do
    issue(conn, "z", 100, "2027-05-02", "z-last")
    issue(conn, "b", 100, "2027-05-01", "b-second")
    issue(conn, "a", 100, "2027-05-01", "a-first")

    assert Enum.map(credit(conn)["lots"], & &1["source_operation_id"]) == [
             "a-first",
             "b-second",
             "z-last"
           ]

    assert [_, %{"amount_cents" => 150, "outstanding_deposit_cents" => 19850, "revision" => 2}, _] =
             batch(conn, [
               open("target", %{"property_id" => "another-hotel"}),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 150,
                 "expected_revision" => 1
               }),
               op("record_cash_payment", "target", %{
                 "amount_cents" => 5,
                 "expected_revision" => 2
               })
             ])

    assert credit(conn)["lots"] == [
             %{
               "source_operation_id" => "b-second",
               "remaining_cents" => 70,
               "expires_on" => "2028-04-30"
             },
             %{
               "source_operation_id" => "z-last",
               "remaining_cents" => 110,
               "expires_on" => "2028-05-01"
             }
           ]

    assert %{
             "cash_paid_cents" => 5,
             "credit_paid_cents" => 150,
             "deposit_paid_cents" => 155,
             "outstanding_deposit_cents" => 19845
           } = read(conn, "groups/target")

    assert ledger(conn)["credit_liability_cents"] == 330
    assert ledger(conn)["cash_held_cents"] == 5

    assert [
             %{
               "credit_issued_cents" => 6,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "revision" => 4
             }
           ] =
             batch(conn, [op("cancel_group", "target", %{"refund_method" => "hotel_credit"})])

    assert credit(conn)["available_cents"] == 336

    assert Enum.find(credit(conn)["lots"], &(&1["source_operation_id"] == "a-first"))[
             "remaining_cents"
           ] == 110

    assert ledger(conn)["credit_liability_cents"] == 336
  end

  test "cash refund restores applied credit and only refunds the cash portion", %{conn: conn} do
    issue(conn, "source", 100)

    batch(conn, [
      open("target"),
      op("apply_hotel_credit", "target", %{"amount_cents" => 110}),
      op("record_cash_payment", "target", %{"amount_cents" => 50})
    ])

    assert [%{"refunded_cents" => 50, "retained_cents" => 0, "credit_issued_cents" => 0}] =
             batch(conn, [op("cancel_group", "target")])

    assert credit(conn)["available_cents"] == 110
    assert ledger(conn)["credit_liability_cents"] == 110
    assert ledger(conn)["cash_refunded_cents"] == 50
  end

  test "expiry is inclusive, redemption pauses expiry, and expired restoration removes liability",
       %{conn: conn} do
    issue(conn, "source", 100)
    batch(conn, [open("target", %{"arrival_on" => "2028-08-01", "departure_on" => "2028-08-02"})])
    assert credit(conn, "2028-05-01")["available_cents"] == 110
    assert credit(conn, "2028-05-02")["available_cents"] == 0
    assert ledger(conn, "2028-05-02")["credit_liability_cents"] == 0
    # Reads do not destroy a lot; application uses the operation date, not the read date.
    assert [%{"status" => "applied"}] =
             batch(conn, [
               op("apply_hotel_credit", "target", %{
                 "occurred_on" => "2028-05-01",
                 "amount_cents" => 70
               })
             ])

    assert ledger(conn, "2028-05-01")["credit_liability_cents"] == 110
    assert ledger(conn, "2028-05-02")["credit_liability_cents"] == 70

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0}] =
             batch(conn, [
               op("cancel_group", "target", %{
                 "occurred_on" => "2028-05-02",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert credit(conn, "2028-05-02")["lots"] == []
    assert ledger(conn, "2028-05-02")["credit_liability_cents"] == 0
  end

  test "restoration on the original expiry day remains available that day", %{conn: conn} do
    issue(conn, "source", 100)

    batch(conn, [
      open("target", %{"arrival_on" => "2028-08-01", "departure_on" => "2028-08-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 110}),
      op("cancel_group", "target", %{"occurred_on" => "2028-05-01"})
    ])

    assert credit(conn, "2028-05-01")["available_cents"] == 110
    assert ledger(conn, "2028-05-02")["credit_liability_cents"] == 0
  end

  test "nonrefundable cancellation consumes credit and retains only cash", %{conn: conn} do
    issue(conn, "source", 100)

    batch(conn, [
      open("target", %{"rate_plan" => "advance_purchase"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 80}),
      op("record_cash_payment", "target", %{"amount_cents" => 20})
    ])

    assert [%{"refunded_cents" => 0, "retained_cents" => 20, "credit_issued_cents" => 0}] =
             batch(conn, [op("cancel_group", "target")])

    assert credit(conn)["available_cents"] == 30
    assert ledger(conn)["credit_liability_cents"] == 30
    assert ledger(conn)["cash_retained_cents"] == 20
    assert Repo.all(CreditAllocation) == []
  end

  test "credit validation is atomic, guest scoped, and batch failures allow later redemption", %{
    conn: conn
  } do
    issue(conn, "source", 100)
    batch(conn, [open("target"), open("other", %{"guest_id" => "other-guest"})])
    before = snapshot()

    for {changes, code} <-
          [
            {%{"amount_cents" => 111}, "insufficient_credit"},
            {%{"amount_cents" => 20001}, "payment_exceeds_outstanding"},
            {%{"amount_cents" => 1, "occurred_on" => "2028-05-02"}, "insufficient_credit"},
            {%{"amount_cents" => 1, "group_id" => "other"}, "insufficient_credit"},
            {%{"amount_cents" => 111, "expected_revision" => 2}, "stale_revision"}
          ] ++ Enum.map([0, -1, 1.5, "10", nil], &{%{"amount_cents" => &1}, "invalid_amount"}) do
      assert [%{"code" => ^code}] = batch(conn, [op("apply_hotel_credit", "target", changes)])
      assert snapshot() == before
    end

    assert [%{"code" => "invalid_operation"}] = batch(conn, [op("apply_hotel_credit", "target")])
    assert snapshot() == before

    assert [
             %{"code" => "insufficient_credit"},
             %{"revision" => 2},
             %{"code" => "stale_revision"},
             %{"revision" => 3}
           ] =
             batch(conn, [
               op("apply_hotel_credit", "target", %{"amount_cents" => 111}),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 50,
                 "expected_revision" => 1
               }),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 60,
                 "expected_revision" => 1
               }),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 60,
                 "expected_revision" => 2
               })
             ])

    assert credit(conn)["lots"] == []
    assert ledger(conn)["credit_liability_cents"] == 110
  end

  test "read dates default to UTC and invalid dates return a client error", %{conn: conn} do
    today = Date.utc_today()
    future = Date.add(today, 60)

    batch(conn, [
      open("today", %{
        "arrival_on" => Date.to_iso8601(future),
        "departure_on" => Date.to_iso8601(Date.add(future, 1))
      }),
      op("record_cash_payment", "today", %{"amount_cents" => 10}),
      op("cancel_group", "today", %{
        "occurred_on" => Date.to_iso8601(today),
        "refund_method" => "hotel_credit"
      })
    ])

    assert read(conn, "guests/guest/credit") == credit(conn, Date.to_iso8601(today))
    assert read(conn, "ledger") == ledger(conn, Date.to_iso8601(today))

    assert read(conn, "guests/unknown/credit") == %{
             "guest_id" => "unknown",
             "available_cents" => 0,
             "lots" => []
           }

    for path <- ["ledger", "guests/guest/credit"],
        query <- ["on=bad", "on=2027-02-29", "on[]=2027-01-01"] do
      assert conn |> get("/api/v1/#{path}?#{query}") |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end

  test "unfunded refundable hotel-credit cancellation creates no empty lot", %{conn: conn} do
    assert [_, %{"credit_issued_cents" => 0, "revision" => 2}] =
             batch(conn, [
               open("empty"),
               op("cancel_group", "empty", %{"refund_method" => "hotel_credit"})
             ])

    assert Repo.all(CreditLot) == []
  end

  test "one batch issues and redeems credit, and both payment types respect mixed outstanding", %{
    conn: conn
  } do
    results =
      batch(conn, [
        open("source"),
        op("record_cash_payment", "source", %{"amount_cents" => 100}),
        op("cancel_group", "source", %{"refund_method" => "hotel_credit"}),
        open("target", %{"rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 500}]}),
        op("record_cash_payment", "target", %{"amount_cents" => 40}),
        op("apply_hotel_credit", "target", %{"amount_cents" => 61}),
        op("apply_hotel_credit", "target", %{"amount_cents" => 60}),
        op("record_cash_payment", "target", %{"amount_cents" => 1}),
        op("apply_hotel_credit", "target", %{"amount_cents" => 1})
      ])

    assert Enum.map(results, & &1["status"]) ==
             [
               "applied",
               "applied",
               "applied",
               "applied",
               "applied",
               "rejected",
               "applied",
               "rejected",
               "rejected"
             ]

    for index <- [5, 7, 8],
        do: assert(Enum.at(results, index)["code"] == "payment_exceeds_outstanding")

    assert %{
             "revision" => 3,
             "cash_paid_cents" => 40,
             "credit_paid_cents" => 60,
             "deposit_paid_cents" => 100,
             "outstanding_deposit_cents" => 0
           } = read(conn, "groups/target")

    assert credit(conn)["available_cents"] == 50
    assert ledger(conn)["credit_liability_cents"] == 110
  end

  test "refundable cancellation restores only unexpired portions of multiple source lots", %{
    conn: conn
  } do
    issue(conn, "earlier", 100, "2027-05-01")
    issue(conn, "later", 100, "2027-05-02")

    batch(conn, [
      open("target", %{"arrival_on" => "2028-08-01", "departure_on" => "2028-08-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 150}),
      op("reschedule_group", "target", %{
        "occurred_on" => "2028-04-01",
        "new_arrival_on" => "2028-09-01"
      })
    ])

    assert %{
             "credit_paid_cents" => 150,
             "policy_version" => "flex-30",
             "refundable_until" => "2028-08-02"
           } = read(conn, "groups/target")

    assert ledger(conn, "2028-05-01")["credit_liability_cents"] == 220
    batch(conn, [op("cancel_group", "target", %{"occurred_on" => "2028-05-01"})])

    assert credit(conn, "2028-05-01")["lots"] == [
             %{
               "source_operation_id" => "cancel-later",
               "remaining_cents" => 110,
               "expires_on" => "2028-05-01"
             }
           ]

    assert ledger(conn, "2028-05-01")["credit_liability_cents"] == 110
    assert ledger(conn, "2028-05-02")["credit_liability_cents"] == 0
  end
end
