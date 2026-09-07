defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerOperations

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  test "opens and reads a priced group with original identifiers and room order", %{conn: conn} do
    opening = open_group(%{"operation_id" => " OP-Ä ", "guest_id" => " guest-22 "})

    assert submit(conn, [opening]) == [
             %{
               "operation_id" => " OP-Ä ",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
           ]

    assert group(conn) == %{
             "group_id" => "group-81",
             "guest_id" => " guest-22 ",
             "property_id" => "ams-canal",
             "revision" => 1,
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "status" => "active",
             "rooms" => opening["rooms"],
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_500
           }

    assert ledger(conn) == empty_ledger()
  end

  test "missing group and empty finance totals have the documented response", %{conn: conn} do
    assert conn |> get("/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}

    assert ledger(conn) == empty_ledger()
  end

  test "an empty operations array is valid", %{conn: conn} do
    assert submit(conn, []) == []
  end

  test "query parameters cannot substitute for an operations array in the body", %{conn: conn} do
    assert conn
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches?operations[]=anything", "{}")
           |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}
  end

  for body <- [
        %{},
        %{"operations" => nil},
        %{"operations" => %{}},
        %{"operations" => "no"},
        [],
        nil,
        42
      ] do
    test "rejects invalid batch #{inspect(body)}", %{conn: conn} do
      assert conn
             |> post_json(unquote(Macro.escape(body)))
             |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}
    end
  end

  test "rounds each flexible room separately, both above and below half a cent", %{conn: conn} do
    for {rate, expected} <- [{3, 2}, {2, 0}] do
      opening =
        open_group(%{
          "group_id" => "rounding-#{rate}",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "a", "nightly_rate_cents" => rate},
            %{"room_id" => "b", "nightly_rate_cents" => rate}
          ]
        })

      assert [%{"deposit_due_cents" => ^expected, "status" => "applied"}] =
               submit(conn, [opening])
    end
  end

  test "advance purchase requires the full lodging amount and permits the same room IDs in other groups",
       %{conn: conn} do
    assert [%{"deposit_due_cents" => 19_500}, %{"deposit_due_cents" => 97_500}] =
             submit(conn, [
               open_group(),
               open_group(%{"group_id" => "another", "rate_plan" => "advance_purchase"})
             ])
  end

  test "integer pricing is exact above floating point precision", %{conn: conn} do
    assert [%{"deposit_due_cents" => 1_801_439_850_948_199}] =
             submit(conn, [
               open_group(%{
                 "departure_on" => "2026-12-11",
                 "rooms" => [
                   %{"room_id" => "large", "nightly_rate_cents" => 9_007_199_254_740_993}
                 ]
               })
             ])
  end

  test "a zero-priced room has no deposit and cannot accept cash", %{conn: conn} do
    assert [%{"deposit_due_cents" => 0}, %{"code" => "payment_exceeds_outstanding"}] =
             submit(conn, [
               open_group(%{"rooms" => [%{"room_id" => "free", "nightly_rate_cents" => 0}]}),
               payment()
             ])
  end

  test "finance totals remain exact when summed cash exceeds a SQLite integer", %{conn: conn} do
    amount = 9_223_372_036_854_775_807

    for id <- ["large-1", "large-2"] do
      assert [%{"status" => "applied"}, %{"status" => "applied"}] =
               submit(conn, [
                 open_group(%{
                   "group_id" => id,
                   "departure_on" => "2026-12-11",
                   "rate_plan" => "advance_purchase",
                   "rooms" => [%{"room_id" => "large", "nightly_rate_cents" => amount}]
                 }),
                 payment(%{"group_id" => id, "amount_cents" => amount})
               ])
    end

    assert ledger(conn)["cash_held_cents"] == amount * 2

    submit(conn, [
      cancellation(%{"group_id" => "large-1"}),
      cancellation(%{"group_id" => "large-2"})
    ])

    assert ledger(conn)["cash_held_cents"] == 0
    assert ledger(conn)["cash_retained_cents"] == amount * 2
  end

  for {name, attributes, code} <- [
        {"same-day stay", %{"departure_on" => "2026-12-10"}, "invalid_stay"},
        {"reversed stay", %{"departure_on" => "2026-12-09"}, "invalid_stay"},
        {"impossible date", %{"arrival_on" => "2026-02-30"}, "invalid_stay"},
        {"non-date arrival", %{"arrival_on" => 10}, "invalid_stay"},
        {"null departure", %{"departure_on" => nil}, "invalid_stay"},
        {"unknown rate plan", %{"rate_plan" => "other"}, "invalid_rate_plan"},
        {"non-string rate plan", %{"rate_plan" => []}, "invalid_rate_plan"},
        {"empty rooms", %{"rooms" => []}, "invalid_rooms"},
        {"null rooms", %{"rooms" => nil}, "invalid_rooms"},
        {"rooms object", %{"rooms" => %{}}, "invalid_rooms"},
        {"malformed room", %{"rooms" => [nil]}, "invalid_rooms"},
        {"missing room price", %{"rooms" => [%{"room_id" => "a"}]}, "invalid_rooms"},
        {"negative rate", %{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => -1}]},
         "invalid_rooms"},
        {"float rate", %{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 1.5}]},
         "invalid_rooms"},
        {"string rate", %{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => "100"}]},
         "invalid_rooms"},
        {"empty room ID", %{"rooms" => [%{"room_id" => "", "nightly_rate_cents" => 100}]},
         "invalid_rooms"},
        {"duplicate room IDs",
         %{
           "rooms" => [
             %{"room_id" => "a", "nightly_rate_cents" => 1},
             %{"room_id" => "a", "nightly_rate_cents" => 2}
           ]
         }, "invalid_rooms"},
        {"unrepresentable lodging",
         %{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 9_223_372_036_854_775_807}]},
         "invalid_rooms"},
        {"invalid booking date", %{"occurred_on" => "yesterday"}, "invalid_operation"},
        {"non-string guest ID", %{"guest_id" => 22}, "invalid_operation"},
        {"empty property ID", %{"property_id" => ""}, "invalid_operation"}
      ] do
    test "rejects #{name} without writing and continues the batch", %{conn: conn} do
      invalid = open_group(unquote(Macro.escape(attributes)))

      assert [%{"code" => unquote(code), "status" => "rejected"}] = submit(conn, [invalid])
      assert snapshot() == {[], []}
      assert ledger(conn) == empty_ledger()

      assert [%{"status" => "rejected"}, %{"status" => "applied"}] =
               submit(conn, [invalid, open_group()])

      assert length(Repo.all(Group)) == 1
      assert length(Repo.all(Room)) == 2
    end
  end

  test "duplicate group IDs preserve the original booking and cash", %{conn: conn} do
    submit(conn, [open_group(), payment()])
    before = snapshot()

    assert [%{"code" => "group_already_exists", "status" => "rejected"}] =
             submit(conn, [open_group(%{"guest_id" => "replacement"})])

    assert snapshot() == before
    assert ledger(conn)["cash_held_cents"] == 1_000
  end

  test "payments accumulate through the exact outstanding balance", %{conn: conn} do
    assert [_, first, second, rejected] =
             submit(conn, [
               open_group(),
               payment(%{"operation_id" => "record_cash_payment-1"}),
               payment(%{"amount_cents" => 18_500}),
               payment()
             ])

    assert first == %{
             "operation_id" => "record_cash_payment-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 1_000,
             "outstanding_deposit_cents" => 18_500,
             "revision" => 2
           }

    assert second["revision"] == 3
    assert second["outstanding_deposit_cents"] == 0
    assert rejected["code"] == "payment_exceeds_outstanding"
    assert group(conn)["deposit_paid_cents"] == 19_500
    assert group(conn)["revision"] == 3
    assert ledger(conn)["cash_held_cents"] == 19_500
  end

  for {amount, code} <- [
        {0, "invalid_amount"},
        {-1, "invalid_amount"},
        {1.0, "invalid_amount"},
        {"100", "invalid_amount"},
        {nil, "invalid_amount"},
        {true, "invalid_amount"},
        {%{}, "invalid_amount"},
        {[], "invalid_amount"},
        {19_501, "payment_exceeds_outstanding"}
      ] do
    test "rejects payment amount #{inspect(amount)} without changing persisted state", %{
      conn: conn
    } do
      submit(conn, [open_group()])
      before = snapshot()

      assert [%{"code" => unquote(code)}] =
               submit(conn, [payment(%{"amount_cents" => unquote(Macro.escape(amount))})])

      assert snapshot() == before
      assert ledger(conn) == empty_ledger()
    end
  end

  test "rescheduling preserves stay length, pricing, rooms, booking date and payments", %{
    conn: conn
  } do
    submit(conn, [open_group(), payment()])
    original = group(conn)

    assert [result] =
             submit(conn, [
               reschedule(%{
                 "operation_id" => "reschedule_group-1",
                 "new_arrival_on" => "2028-02-28"
               })
             ])

    assert result == %{
             "operation_id" => "reschedule_group-1",
             "status" => "applied",
             "group_id" => "group-81",
             "new_arrival_on" => "2028-02-28",
             "new_departure_on" => "2028-03-02",
             "policy_version" => "flex-14",
             "refundable_until" => "2028-02-14",
             "revision" => 3
           }

    assert group(conn) ==
             Map.merge(original, %{
               "arrival_on" => "2028-02-28",
               "departure_on" => "2028-03-02",
               "refundable_until" => "2028-02-14",
               "revision" => 3
             })

    assert [%{"new_departure_on" => "2026-11-05", "revision" => 4}] =
             submit(conn, [reschedule(%{"new_arrival_on" => "2026-11-02"})])
  end

  test "moving to the current arrival still increments the revision once", %{conn: conn} do
    assert [_, %{"revision" => 2}] =
             submit(conn, [open_group(), reschedule(%{"new_arrival_on" => "2026-12-10"})])
  end

  for arrival <- [
        "2026-11-01",
        "2026-10-31",
        "2026-02-29",
        "9999-12-31",
        "not-a-date",
        nil,
        123,
        %{}
      ] do
    test "rejects unusable reschedule date #{inspect(arrival)}", %{conn: conn} do
      submit(conn, [open_group(), payment()])
      before = snapshot()

      assert [%{"code" => "invalid_stay"}] =
               submit(conn, [reschedule(%{"new_arrival_on" => unquote(Macro.escape(arrival))})])

      assert snapshot() == before
      assert ledger(conn)["cash_held_cents"] == 1_000
    end
  end

  for {plan, date, refunded, retained} <- [
        {"flexible", "2026-11-25", 1_000, 0},
        {"flexible", "2026-11-26", 1_000, 0},
        {"flexible", "2026-11-27", 0, 1_000},
        {"flexible", "2026-12-10", 0, 1_000},
        {"flexible", "2026-12-15", 0, 1_000},
        {"advance_purchase", "2026-11-01", 0, 1_000}
      ] do
    test "settles #{plan} cancellation on #{date} using only paid cash", %{conn: conn} do
      assert [_, _, result] =
               submit(conn, [
                 open_group(%{"rate_plan" => unquote(plan)}),
                 payment(),
                 cancellation(%{
                   "operation_id" => "cancel_group-1",
                   "occurred_on" => unquote(date)
                 })
               ])

      assert result == %{
               "operation_id" => "cancel_group-1",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => unquote(refunded),
               "retained_cents" => unquote(retained),
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert %{
               "status" => "cancelled",
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 1_000,
               "outstanding_deposit_cents" => 0,
               "lodging_total_cents" => 97_500,
               "revision" => 3
             } = group(conn)

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => unquote(refunded),
               "cash_retained_cents" => unquote(retained),
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end
  end

  test "cancelling an unpaid group clears its deposit without inventing cash", %{conn: conn} do
    assert [_, %{"refunded_cents" => 0, "retained_cents" => 0, "revision" => 2}] =
             submit(conn, [open_group(), cancellation()])

    assert ledger(conn) == empty_ledger()
    assert group(conn)["outstanding_deposit_cents"] == 0
  end

  test "cancellation uses the rescheduled arrival for its refund boundary", %{conn: conn} do
    assert [_, _, _, %{"refunded_cents" => 0, "retained_cents" => 1_000}] =
             submit(conn, [
               open_group(),
               payment(),
               reschedule(%{"new_arrival_on" => "2026-11-14"}),
               cancellation()
             ])
  end

  test "ledger combines held, refunded and retained cash across properties", %{conn: conn} do
    submit(conn, [
      open_group(),
      payment(),
      open_group(%{"group_id" => "refunded", "property_id" => "paris"}),
      payment(%{"group_id" => "refunded", "amount_cents" => 2_000}),
      cancellation(%{"group_id" => "refunded"}),
      open_group(%{"group_id" => "retained", "rate_plan" => "advance_purchase"}),
      payment(%{"group_id" => "retained", "amount_cents" => 3_000}),
      cancellation(%{"group_id" => "retained"}),
      open_group(%{"group_id" => "unpaid"})
    ])

    assert ledger(conn) == %{
             "cash_held_cents" => 1_000,
             "cash_refunded_cents" => 2_000,
             "cash_retained_cents" => 3_000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  for operation <- [payment(), credit_payment(), reschedule(), cancellation()] do
    @operation operation

    test "#{operation["type"]} resolves missing groups before revisions or domain rules", %{
      conn: conn
    } do
      invalid =
        Map.merge(@operation, %{
          "expected_revision" => 20,
          "amount_cents" => -1,
          "new_arrival_on" => nil
        })

      assert [%{"code" => "group_not_found"}] = submit(conn, [invalid])
      assert snapshot() == {[], []}
    end

    test "#{operation["type"]} rejects inactive groups without changing state", %{conn: conn} do
      submit(conn, [open_group(), payment(), cancellation()])
      before = snapshot()
      assert [%{"code" => "group_not_active"}] = submit(conn, [@operation])
      assert snapshot() == before
      assert ledger(conn)["cash_refunded_cents"] == 1_000
    end

    test "#{operation["type"]} checks stale revisions before inactive status or malformed data",
         %{conn: conn} do
      submit(conn, [open_group(), cancellation()])
      before = snapshot()

      invalid =
        Map.merge(@operation, %{
          "expected_revision" => 1,
          "amount_cents" => -1,
          "new_arrival_on" => nil,
          "occurred_on" => nil
        })

      assert [result] = submit(conn, [invalid])

      assert result == %{
               "operation_id" => @operation["operation_id"],
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert snapshot() == before
      assert ledger(conn) == empty_ledger()
    end
  end

  test "revisions see earlier successes, survive rejections, and are ignored when opening", %{
    conn: conn
  } do
    assert [opened, paid, stale, moved, cancelled] =
             submit(conn, [
               open_group(%{"expected_revision" => -100}),
               payment(%{"expected_revision" => 1}),
               payment(%{"expected_revision" => 1}),
               reschedule(%{"expected_revision" => 2}),
               cancellation(%{"expected_revision" => 3})
             ])

    assert opened["revision"] == 1
    assert paid["revision"] == 2
    assert stale["code"] == "stale_revision"
    assert stale["actual_revision"] == 2
    assert moved["revision"] == 3
    assert cancelled["revision"] == 4
    assert group(conn)["revision"] == 4
    assert ledger(conn)["cash_refunded_cents"] == 1_000
  end

  test "a domain rejection does not consume the expected revision", %{conn: conn} do
    assert [_, %{"code" => "invalid_amount"}, %{"revision" => 2}] =
             submit(conn, [
               open_group(),
               payment(%{"amount_cents" => 0, "expected_revision" => 1}),
               payment(%{"expected_revision" => 1})
             ])
  end

  test "non-integer expected revisions do not match an integer revision", %{conn: conn} do
    submit(conn, [open_group()])

    for revision <- [nil, 1.0, "1", true, %{}] do
      assert [%{"code" => "stale_revision", "expected_revision" => ^revision}] =
               submit(conn, [payment(%{"expected_revision" => revision})])
    end

    assert group(conn)["revision"] == 1
  end

  test "malformed operations yield one rejection each and do not stop later operations", %{
    conn: conn
  } do
    malformed = [
      nil,
      10,
      "open_group",
      [],
      %{},
      operation("unknown"),
      payment(%{"group_id" => nil}),
      payment(%{"operation_id" => ""})
    ]

    results = submit(conn, malformed ++ [open_group(), payment()])

    assert length(results) == length(malformed) + 2
    assert Enum.all?(Enum.take(results, length(malformed)), &(&1["code"] == "invalid_operation"))
    assert Enum.map(Enum.take(results, -2), & &1["revision"]) == [1, 2]
    assert ledger(conn)["cash_held_cents"] == 1_000
  end

  test "missing required opening fields are invalid operations", %{conn: conn} do
    for field <-
          ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms) do
      assert [%{"code" => "invalid_operation"}] = submit(conn, [Map.delete(open_group(), field)])
      assert snapshot() == {[], []}
    end
  end

  test "missing update data and malformed operation dates preserve the database", %{conn: conn} do
    submit(conn, [open_group()])
    before = snapshot()

    malformed = [
      Map.delete(payment(), "amount_cents"),
      Map.delete(reschedule(), "new_arrival_on"),
      Map.delete(payment(), "occurred_on"),
      reschedule(%{"occurred_on" => "2026-02-30"}),
      cancellation(%{"occurred_on" => []})
    ]

    assert Enum.all?(submit(conn, malformed), &(&1["code"] == "invalid_operation"))
    assert snapshot() == before
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp submit(conn, operations) do
    conn
    |> post_json(%{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn) do
    conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn), do: conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

  defp empty_ledger do
    %{
      "cash_held_cents" => 0,
      "cash_refunded_cents" => 0,
      "cash_retained_cents" => 0,
      "cash_converted_to_credit_cents" => 0,
      "credit_liability_cents" => 0
    }
  end

  defp snapshot, do: {Repo.all(Group), Repo.all(Room)}
end
