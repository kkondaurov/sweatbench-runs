defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ReservationFixtures
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group}

  for {booked_on, policy, deadline} <- [
        {"2026-12-31", "flex-14", "2027-03-18"},
        {"2027-01-01", "flex-30", "2027-03-02"}
      ] do
    test "booking on #{booked_on} fixes #{policy} across rescheduling", %{conn: conn} do
      batch(conn, [
        open_operation(%{
          "occurred_on" => unquote(booked_on),
          "arrival_on" => "2027-04-01",
          "departure_on" => "2027-04-04"
        })
      ])

      before = group(conn)
      assert before["policy_version"] == unquote(policy)
      assert before["refundable_until"] == unquote(deadline)

      [moved] =
        batch(conn, [
          operation("reschedule_group", %{
            "occurred_on" => "2028-01-01",
            "new_arrival_on" => "2028-04-01",
            "expected_revision" => 1
          })
        ])

      assert moved["revision"] == 2
      assert moved["policy_version"] == unquote(policy)
      assert moved["new_departure_on"] == "2028-04-04"
      assert moved["refundable_until"] == String.replace(unquote(deadline), "2027", "2028")
      assert group(conn)["booked_on"] == unquote(booked_on)
      assert group(conn)["deposit_due_cents"] == before["deposit_due_cents"]
    end
  end

  for {on, refunded, retained} <- [
        {"2027-03-01", 100, 0},
        {"2027-03-02", 100, 0},
        {"2027-03-03", 0, 100}
      ] do
    test "flex-30 cash cancellation on #{on} respects the inclusive deadline", %{conn: conn} do
      [_, _, cancelled] =
        batch(conn, [
          open_operation(%{
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-04-01",
            "departure_on" => "2027-04-04"
          }),
          operation("record_cash_payment", %{"amount_cents" => 100}),
          operation("cancel_group", %{"occurred_on" => unquote(on)})
        ])

      assert cancelled["refunded_cents"] == unquote(refunded)
      assert cancelled["retained_cents"] == unquote(retained)
      assert cancelled["credit_issued_cents"] == 0
      assert cancelled["revision"] == 3
    end
  end

  test "advance purchase has no deadline even after rescheduling", %{conn: conn} do
    [_, moved] =
      batch(conn, [
        open_operation(%{"rate_plan" => "advance_purchase", "occurred_on" => "2027-01-01"}),
        operation("reschedule_group", %{"new_arrival_on" => "2028-04-01"})
      ])

    assert group(conn)["policy_version"] == "advance-nonrefundable"
    assert group(conn)["refundable_until"] == nil
    assert moved["policy_version"] == "advance-nonrefundable"
    assert moved["refundable_until"] == nil

    rejected(
      conn,
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      "refund_method_not_available"
    )
  end

  test "a flex-30 deadline cancellation issues credit usable later in the same batch", %{
    conn: conn
  } do
    results =
      batch(conn, [
        open_operation(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-04-01",
          "departure_on" => "2027-04-04"
        }),
        operation("record_cash_payment", %{"occurred_on" => "2027-01-01", "amount_cents" => 105}),
        operation("cancel_group", %{
          "occurred_on" => "2027-03-03",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }),
        operation("cancel_group", %{
          "occurred_on" => "2027-03-02",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }),
        open_operation(%{
          "group_id" => "target",
          "occurred_on" => "2027-03-02",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04",
          "rate_plan" => "advance_purchase"
        }),
        operation("apply_hotel_credit", %{
          "group_id" => "target",
          "occurred_on" => "2027-03-02",
          "amount_cents" => 116,
          "expected_revision" => 1
        }),
        operation("cancel_group", %{
          "group_id" => "target",
          "occurred_on" => "2027-03-02",
          "expected_revision" => 2
        })
      ])

    assert Enum.map(results, & &1["status"]) == [
             "applied",
             "applied",
             "rejected",
             "applied",
             "applied",
             "applied",
             "applied"
           ]

    assert Enum.at(results, 2)["code"] == "refund_method_not_available"
    assert Enum.at(results, 3)["credit_issued_cents"] == 116
    assert Enum.at(results, 3)["revision"] == 3
    assert Enum.at(results, 5)["revision"] == 2
    assert List.last(results)["refunded_cents"] == 0
    assert List.last(results)["retained_cents"] == 0
    assert List.last(results)["credit_issued_cents"] == 0
    assert group(conn, "target")["credit_paid_cents"] == 0
    assert credit(conn, "2027-03-02")["available_cents"] == 0
    assert ledger(conn, "2027-03-02")["credit_liability_cents"] == 0
    assert ledger(conn, "2027-03-02")["cash_converted_to_credit_cents"] == 105
  end

  test "credit cancellation rounds the bonus half upward and expires after 365 days", %{
    conn: conn
  } do
    result = issue(conn, "source", " Cancel-Å ", 105, "2027-05-03")

    assert result == %{
             "operation_id" => " Cancel-Å ",
             "status" => "applied",
             "group_id" => "source",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 116,
             "revision" => 3
           }

    assert credit(conn, "2028-05-02") == %{
             "guest_id" => "guest-22",
             "available_cents" => 116,
             "lots" => [
               %{
                 "source_operation_id" => " Cancel-Å ",
                 "remaining_cents" => 116,
                 "expires_on" => "2028-05-02"
               }
             ]
           }

    assert ledger(conn, "2028-05-02") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 105,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 116
           }

    assert credit(conn, "2028-05-03")["lots"] == []
    assert ledger(conn, "2028-05-03")["credit_liability_cents"] == 0
    assert ledger(conn, "2028-05-03")["cash_converted_to_credit_cents"] == 105
    # Expiry reads are projections; later reads must not destroy earlier-date availability.
    assert credit(conn, "2028-05-02")["available_cents"] == 116
    assert group(conn, "source")["cash_paid_cents"] == 0
    assert group(conn, "source")["credit_paid_cents"] == 0
  end

  for {cash, credit} <- [{104, 114}, {106, 117}, {9_007_199_254_740_995, 9_907_919_180_215_095}] do
    test "bonus stays exact for #{cash} cents", %{conn: conn} do
      assert issue(conn, "source", "cancel", unquote(cash))["credit_issued_cents"] ==
               unquote(credit)
    end
  end

  test "unpaid and credit-only cancellations issue no new lot", %{conn: conn} do
    batch(conn, [open_operation()])
    [result] = batch(conn, [operation("cancel_group", %{"refund_method" => "hotel_credit"})])
    assert result["credit_issued_cents"] == 0
    assert Repo.all(CreditLot) == []
    issue(conn, "source", "cancel-source", 100)

    batch(conn, [
      open_operation(%{"group_id" => "target"}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110})
    ])

    [cancelled] =
      batch(conn, [
        operation("cancel_group", %{"group_id" => "target", "refund_method" => "hotel_credit"})
      ])

    assert cancelled["credit_issued_cents"] == 0
    assert credit(conn, "2026-10-04")["available_cents"] == 110
    assert length(Repo.all(CreditLot)) == 1
  end

  test "credit is redeemed by expiry and source ID, across properties and in batch order", %{
    conn: conn
  } do
    # Deliberately issue in a different order from redemption order.
    issue(conn, "later", "a-later", 100, "2026-10-05")
    issue(conn, "same-z", "z-source", 100)
    issue(conn, "same-a", "a-source", 100)

    assert Enum.map(credit(conn, "2026-10-06")["lots"], & &1["source_operation_id"]) == [
             "a-source",
             "z-source",
             "a-later"
           ]

    [_, applied, paid] =
      batch(conn, [
        open_operation(%{"property_id" => "other-property"}),
        operation("apply_hotel_credit", %{
          "operation_id" => "op-apply_hotel_credit",
          "amount_cents" => 150,
          "expected_revision" => 1
        }),
        operation("record_cash_payment", %{"amount_cents" => 50, "expected_revision" => 2})
      ])

    assert applied == %{
             "operation_id" => "op-apply_hotel_credit",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 150,
             "outstanding_deposit_cents" => 19_350,
             "revision" => 2
           }

    assert paid["revision"] == 3

    assert Map.take(
             group(conn),
             ~w(cash_paid_cents credit_paid_cents deposit_paid_cents outstanding_deposit_cents)
           ) == %{
             "cash_paid_cents" => 50,
             "credit_paid_cents" => 150,
             "deposit_paid_cents" => 200,
             "outstanding_deposit_cents" => 19_300
           }

    assert Enum.map(
             credit(conn, "2026-10-06")["lots"],
             &{&1["source_operation_id"], &1["remaining_cents"]}
           ) == [{"z-source", 70}, {"a-later", 110}]

    assert ledger(conn, "2026-10-06")["cash_held_cents"] == 50
    assert ledger(conn, "2026-10-06")["credit_liability_cents"] == 330

    # A second redemption from the same lot must also be restored.
    batch(conn, [operation("apply_hotel_credit", %{"amount_cents" => 30})])
    [cancelled] = batch(conn, [operation("cancel_group", %{"refund_method" => "cash"})])
    assert cancelled["refunded_cents"] == 50
    assert cancelled["retained_cents"] == 0
    assert cancelled["credit_issued_cents"] == 0

    assert Enum.map(credit(conn, "2026-10-06")["lots"], & &1["remaining_cents"]) == [
             110,
             110,
             110
           ]

    assert ledger(conn, "2026-10-06")["credit_liability_cents"] == 330
  end

  test "refundable mixed funding restores old credit and gives only new cash a bonus", %{
    conn: conn
  } do
    issue(conn, "source", "original", 100)

    [_, _, _, cancelled] =
      batch(conn, [
        open_operation(),
        operation("apply_hotel_credit", %{"amount_cents" => 80}),
        operation("record_cash_payment", %{"amount_cents" => 105}),
        operation("cancel_group", %{
          "operation_id" => "new-credit",
          "occurred_on" => "2026-10-05",
          "refund_method" => "hotel_credit",
          "expected_revision" => 3
        })
      ])

    assert cancelled["credit_issued_cents"] == 116
    assert cancelled["refunded_cents"] == 0
    assert cancelled["retained_cents"] == 0
    assert cancelled["revision"] == 4

    assert credit(conn, "2026-10-05")["lots"] == [
             %{
               "source_operation_id" => "original",
               "remaining_cents" => 110,
               "expires_on" => "2027-10-04"
             },
             %{
               "source_operation_id" => "new-credit",
               "remaining_cents" => 116,
               "expires_on" => "2027-10-05"
             }
           ]

    assert ledger(conn, "2026-10-05")["cash_converted_to_credit_cents"] == 205
    assert ledger(conn, "2026-10-05")["credit_liability_cents"] == 226
  end

  for {cancel_on, available, liability} <- [
        {"2027-10-04", 110, 110},
        {"2027-10-05", 0, 0}
      ] do
    test "credit expiry pauses while redeemed and restoration on #{cancel_on} honors the original expiry",
         %{conn: conn} do
      issue(conn, "source", "original", 100)

      batch(conn, [
        open_operation(%{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-04"}),
        operation("apply_hotel_credit", %{"amount_cents" => 80})
      ])

      assert credit(conn, "2027-10-05")["available_cents"] == 0
      assert ledger(conn, "2027-10-05")["credit_liability_cents"] == 80

      [cancelled] =
        batch(conn, [operation("cancel_group", %{"occurred_on" => unquote(cancel_on)})])

      assert cancelled["credit_issued_cents"] == 0
      assert credit(conn, unquote(cancel_on))["available_cents"] == unquote(available)
      assert ledger(conn, unquote(cancel_on))["credit_liability_cents"] == unquote(liability)
      assert group(conn)["credit_paid_cents"] == 0
    end
  end

  test "restoration across lots expires only the amounts whose original expiry has passed", %{
    conn: conn
  } do
    issue(conn, "old", "old", 100)
    issue(conn, "new", "new", 100, "2026-10-06")

    batch(conn, [
      open_operation(%{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-04"}),
      operation("apply_hotel_credit", %{"amount_cents" => 200}),
      operation("cancel_group", %{"occurred_on" => "2027-10-05"})
    ])

    assert credit(conn, "2027-10-05")["lots"] == [
             %{
               "source_operation_id" => "new",
               "remaining_cents" => 110,
               "expires_on" => "2027-10-06"
             }
           ]

    assert ledger(conn, "2027-10-05")["credit_liability_cents"] == 110
  end

  test "non-refundable mixed cancellation retains cash and consumes applied credit", %{conn: conn} do
    issue(conn, "source", "original", 100)

    batch(conn, [
      open_operation(),
      operation("apply_hotel_credit", %{"amount_cents" => 80}),
      operation("record_cash_payment", %{"amount_cents" => 50})
    ])

    unavailable =
      operation("cancel_group", %{
        "occurred_on" => "2026-11-27",
        "refund_method" => "hotel_credit",
        "expected_revision" => 3
      })

    rejected(conn, unavailable, "refund_method_not_available")

    [cancelled] =
      batch(conn, [
        Map.merge(unavailable, %{"operation_id" => "cancel-with-cash", "refund_method" => "cash"})
      ])

    assert cancelled["revision"] == 4
    assert cancelled["refunded_cents"] == 0
    assert cancelled["retained_cents"] == 50
    assert cancelled["credit_issued_cents"] == 0
    assert credit(conn, "2026-11-27")["available_cents"] == 30
    assert ledger(conn, "2026-11-27")["credit_liability_cents"] == 30
    assert ledger(conn, "2026-11-27")["cash_retained_cents"] == 50
    assert group(conn)["deposit_paid_cents"] == 0
  end

  test "expired lots cannot fund a new deposit but remain usable on their expiry date", %{
    conn: conn
  } do
    issue(conn, "source", "original", 100)
    batch(conn, [open_operation()])

    rejected(
      conn,
      operation("apply_hotel_credit", %{"amount_cents" => 110, "occurred_on" => "2027-10-05"}),
      "insufficient_credit"
    )

    [applied] =
      batch(conn, [
        operation("apply_hotel_credit", %{"amount_cents" => 110, "occurred_on" => "2027-10-04"})
      ])

    assert applied["revision"] == 2
    assert credit(conn, "2027-10-04")["lots"] == []
    assert ledger(conn, "2028-01-01")["credit_liability_cents"] == 110
  end

  test "credit validation preserves all rows and follows revision precedence", %{conn: conn} do
    issue(conn, "source", "original", 100)
    batch(conn, [open_operation()])

    for amount <- [0, -1, 1.0, "1", nil, true, [], %{}] do
      rejected(
        conn,
        operation("apply_hotel_credit", %{"amount_cents" => amount}),
        "invalid_amount"
      )
    end

    rejected(conn, operation("apply_hotel_credit"), "invalid_operation")

    rejected(
      conn,
      operation("apply_hotel_credit", %{"amount_cents" => 111}),
      "insufficient_credit"
    )

    rejected(
      conn,
      operation("apply_hotel_credit", %{"amount_cents" => 19_501}),
      "payment_exceeds_outstanding"
    )

    rejected(
      conn,
      operation("apply_hotel_credit", %{"amount_cents" => 100, "occurred_on" => "invalid"}),
      "invalid_operation"
    )

    for method <- [nil, "wire", 123, %{}, []] do
      rejected(conn, operation("cancel_group", %{"refund_method" => method}), "invalid_operation")
    end

    for op <- [
          operation("apply_hotel_credit", %{"amount_cents" => 111}),
          operation("apply_hotel_credit", %{"amount_cents" => -1}),
          operation("cancel_group", %{"refund_method" => "invalid"}),
          operation("cancel_group", %{
            "refund_method" => "hotel_credit",
            "occurred_on" => "2026-11-27"
          })
        ] do
      stale = rejected(conn, Map.put(op, "expected_revision", 0), "stale_revision")
      assert stale["actual_revision"] == 1
      assert stale["expected_revision"] == 0
      assert stale["group_id"] == "group-81"
    end

    batch(conn, [open_operation(%{"group_id" => "other-guest", "guest_id" => "other"})])

    rejected(
      conn,
      operation("apply_hotel_credit", %{"group_id" => "other-guest", "amount_cents" => 1}),
      "insufficient_credit"
    )

    assert credit(conn, "2026-10-04", "other")["lots"] == []

    [applied] =
      batch(conn, [
        operation("apply_hotel_credit", %{"amount_cents" => 110, "expected_revision" => 1})
      ])

    assert applied["revision"] == 2
  end

  test "cash and credit share the outstanding limit and failed operations do not stop the batch",
       %{conn: conn} do
    issue(conn, "source", "original", 100)

    results =
      batch(conn, [
        open_operation(),
        operation("record_cash_payment", %{"amount_cents" => 19_450}),
        operation("apply_hotel_credit", %{"amount_cents" => 51, "expected_revision" => 2}),
        operation("apply_hotel_credit", %{"amount_cents" => 50, "expected_revision" => 2}),
        operation("record_cash_payment", %{"amount_cents" => 1, "expected_revision" => 3})
      ])

    assert Enum.map(results, & &1["status"]) == [
             "applied",
             "applied",
             "rejected",
             "applied",
             "rejected"
           ]

    assert Enum.at(results, 2)["code"] == "payment_exceeds_outstanding"
    assert Enum.at(results, 4)["code"] == "payment_exceeds_outstanding"
    assert group(conn)["outstanding_deposit_cents"] == 0
    assert group(conn)["revision"] == 3
    assert credit(conn, "2026-10-04")["available_cents"] == 60
  end

  test "credit and ledger reads default to UTC today, validate dates and preserve guest IDs", %{
    conn: conn
  } do
    today = Date.utc_today()
    issue(conn, "expired", "expired", 100, Date.to_iso8601(Date.add(today, -366)))
    issue(conn, "valid", "valid", 100, Date.to_iso8601(Date.add(today, -365)))
    assert credit(conn)["available_cents"] == 110
    assert ledger(conn)["credit_liability_cents"] == 110
    assert credit(conn) == credit(conn, Date.to_iso8601(today))
    assert ledger(conn) == ledger(conn, Date.to_iso8601(today))

    assert credit(conn, nil, " Guest-Å ") == %{
             "guest_id" => " Guest-Å ",
             "available_cents" => 0,
             "lots" => []
           }

    for path <- ["/api/v1/ledger", "/api/v1/guests/guest-22/credit"],
        date <- ["bad", "2027-02-29", "", "2027-01-01T00:00:00Z"] do
      assert conn |> get(path <> "?" <> URI.encode_query(%{"on" => date})) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end
  end

  defp issue(conn, group_id, source_id, cash, on \\ "2026-10-04") do
    [_, _, result] =
      batch(conn, [
        open_operation(%{
          "group_id" => group_id,
          "occurred_on" => on,
          "arrival_on" => Date.to_iso8601(Date.add(Date.from_iso8601!(on), 60)),
          "departure_on" => Date.to_iso8601(Date.add(Date.from_iso8601!(on), 61)),
          "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => cash * 5}]
        }),
        operation("record_cash_payment", %{
          "group_id" => group_id,
          "amount_cents" => cash,
          "occurred_on" => on
        }),
        operation("cancel_group", %{
          "group_id" => group_id,
          "operation_id" => source_id,
          "occurred_on" => on,
          "refund_method" => "hotel_credit"
        })
      ])

    assert result["status"] == "applied"
    result
  end

  defp batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn, id \\ "group-81") do
    conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp credit(conn, on \\ nil, guest \\ "guest-22") do
    read(conn, "/api/v1/guests/#{URI.encode(guest, &URI.char_unreserved?/1)}/credit", on)
  end

  defp ledger(conn, on \\ nil), do: read(conn, "/api/v1/ledger", on)

  defp read(conn, path, on) do
    path = if on, do: path <> "?" <> URI.encode_query(%{"on" => on}), else: path
    conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  defp rejected(conn, op, code) do
    before = snapshot()
    assert [%{"status" => "rejected", "code" => ^code} = result] = batch(conn, [op])
    assert result["operation_id"] == op["operation_id"]
    assert snapshot() == before
    result
  end

  defp snapshot, do: {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation)}
end
