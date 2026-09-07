defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerOperations

  alias GroupStay.Repo
  alias GroupStay.HotelCredit.{Application, Lot}
  alias GroupStay.Reservations.{Group, Room}

  for {booked, plan, version, deadline} <- [
        {"2026-12-31", "flexible", "flex-14", "2027-03-18"},
        {"2027-01-01", "flexible", "flex-30", "2027-03-02"},
        {"2027-02-01", "flexible", "flex-30", "2027-03-02"},
        {"2026-12-31", "advance_purchase", "advance-nonrefundable", nil},
        {"2027-01-01", "advance_purchase", "advance-nonrefundable", nil}
      ] do
    moved_deadline = if deadline, do: String.replace(deadline, "2027", "2028"), else: nil

    test "booking on #{booked} fixes #{plan} policy to #{version}", %{conn: conn} do
      submit(conn, [
        open_group(%{
          "occurred_on" => unquote(booked),
          "rate_plan" => unquote(plan),
          "arrival_on" => "2027-04-01",
          "departure_on" => "2027-04-04"
        })
      ])

      assert %{"policy_version" => unquote(version), "refundable_until" => unquote(deadline)} =
               group(conn)

      assert [moved] =
               submit(conn, [
                 reschedule(%{
                   "occurred_on" => "2028-01-01",
                   "new_arrival_on" => "2028-04-01"
                 })
               ])

      assert moved["policy_version"] == unquote(version)
      assert moved["new_departure_on"] == "2028-04-04"
      assert moved["refundable_until"] == group(conn)["refundable_until"]

      assert moved["refundable_until"] == unquote(moved_deadline)

      assert group(conn)["booked_on"] == unquote(booked)
    end
  end

  for {booked, cancelled, refunded, retained} <- [
        {"2026-12-31", "2027-03-18", 1_000, 0},
        {"2026-12-31", "2027-03-19", 0, 1_000},
        {"2027-01-01", "2027-03-01", 1_000, 0},
        {"2027-01-01", "2027-03-02", 1_000, 0},
        {"2027-01-01", "2027-03-03", 0, 1_000}
      ] do
    test "cash settlement for booking #{booked} on #{cancelled}", %{conn: conn} do
      assert [_, _, result] =
               submit(conn, [
                 open_group(%{
                   "occurred_on" => unquote(booked),
                   "arrival_on" => "2027-04-01",
                   "departure_on" => "2027-04-04"
                 }),
                 payment(),
                 cancellation(%{"occurred_on" => unquote(cancelled)})
               ])

      assert result["refunded_cents"] == unquote(refunded)
      assert result["retained_cents"] == unquote(retained)
      assert result["credit_issued_cents"] == 0
      assert result["revision"] == 3
    end
  end

  for {cash, issued} <- [{4, 4}, {5, 6}, {6, 7}, {505, 556}, {5_000, 5_500}] do
    test "issuing credit for #{cash} cents rounds the bonus to #{issued - cash}", %{conn: conn} do
      result = issue(conn, "source", unquote(cash), "2027-05-03")

      assert result == %{
               "operation_id" => "source",
               "group_id" => "source",
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => unquote(issued),
               "revision" => 3
             }

      assert credit(conn, "2028-05-02") == %{
               "guest_id" => "guest-22",
               "available_cents" => unquote(issued),
               "lots" => [
                 %{
                   "source_operation_id" => "source",
                   "remaining_cents" => unquote(issued),
                   "expires_on" => "2028-05-02"
                 }
               ]
             }

      assert ledger(conn, "2028-05-02") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => unquote(cash),
               "credit_liability_cents" => unquote(issued)
             }

      assert credit(conn, "2028-05-03")["lots"] == []
      assert ledger(conn, "2028-05-03")["credit_liability_cents"] == 0
      assert ledger(conn, "2028-05-03")["cash_converted_to_credit_cents"] == unquote(cash)
    end
  end

  test "credit reads preserve guest identifiers and default to the current UTC date", %{
    conn: conn
  } do
    today = Date.utc_today()
    issue(conn, "expired", 100, Date.to_iso8601(Date.add(today, -366)), " guest-Ä ")
    issue(conn, "last-day", 200, Date.to_iso8601(Date.add(today, -365)), " guest-Ä ")
    issue(conn, "future", 300, Date.to_iso8601(today), " guest-Ä ")

    assert read(conn, "/api/v1/guests/#{URI.encode(" guest-Ä ", &URI.char_unreserved?/1)}/credit") ==
             credit(conn, Date.to_iso8601(today), " guest-Ä ")

    assert read(conn, "/api/v1/ledger") == ledger(conn, Date.to_iso8601(today))
    assert credit(conn, Date.to_iso8601(today), " guest-Ä ")["available_cents"] == 550

    assert credit(conn, Date.to_iso8601(today), "missing") == %{
             "guest_id" => "missing",
             "available_cents" => 0,
             "lots" => []
           }
  end

  test "both expiry reads reject malformed dates without changing state", %{conn: conn} do
    issue(conn, "source", 100)
    before = snapshot()

    for path <- ["/api/v1/ledger", "/api/v1/guests/guest-22/credit"],
        query <- ["on=bad", "on=2027-02-29", "on=", "on[]=2027-01-01"] do
      assert conn |> get(path <> "?" <> query) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end

    assert snapshot() == before
  end

  test "lots are consumed by expiry then operation ID and repeated applications restore once", %{
    conn: conn
  } do
    issue(conn, "later-a", 100, "2026-11-02")
    issue(conn, "early-z", 100)
    issue(conn, "early-a", 100)
    submit(conn, [open_group()])

    assert Enum.map(credit(conn)["lots"], & &1["source_operation_id"]) ==
             ["early-a", "early-z", "later-a"]

    assert [first, second] =
             submit(conn, [
               credit_payment(%{"amount_cents" => 150, "expected_revision" => 1}),
               credit_payment(%{"amount_cents" => 30, "expected_revision" => 2})
             ])

    assert first == %{
             "operation_id" => "apply_hotel_credit-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 150,
             "outstanding_deposit_cents" => 19_350,
             "revision" => 2
           }

    assert second["revision"] == 3

    assert Enum.map(credit(conn)["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) ==
             [{"early-z", 40}, {"later-a", 110}]

    assert ledger(conn)["credit_liability_cents"] == 330
    assert group(conn)["credit_paid_cents"] == 180
    assert group(conn)["cash_paid_cents"] == 0

    assert [%{"credit_issued_cents" => 0, "revision" => 4}] =
             submit(conn, [cancellation(%{"refund_method" => "hotel_credit"})])

    assert credit(conn)["available_cents"] == 330
    assert Enum.map(credit(conn)["lots"], & &1["remaining_cents"]) == [110, 110, 110]
    assert Repo.aggregate(Lot, :count) == 3
    assert group(conn)["credit_paid_cents"] == 180
    assert group(conn)["deposit_paid_cents"] == 180
    assert ledger(conn)["credit_liability_cents"] == 330
  end

  for method <- ["cash", "hotel_credit"] do
    test "refundable mixed funding with #{method} restores original credit without another bonus",
         %{
           conn: conn
         } do
      issue(conn, "source", 1_000)

      assert [_, _, _, settled] =
               submit(conn, [
                 open_group(),
                 credit_payment(%{"amount_cents" => 600}),
                 payment(%{"amount_cents" => 505}),
                 cancellation(%{
                   "operation_id" => "mixed",
                   "occurred_on" => "2026-11-26",
                   "refund_method" => unquote(method)
                 })
               ])

      issued = if unquote(method) == "hotel_credit", do: 556, else: 0
      refunded = if unquote(method) == "cash", do: 505, else: 0

      assert settled["credit_issued_cents"] == issued
      assert settled["refunded_cents"] == refunded
      assert settled["retained_cents"] == 0
      assert settled["revision"] == 4

      assert %{
               "cash_paid_cents" => 505,
               "credit_paid_cents" => 600,
               "deposit_paid_cents" => 1_105,
               "deposit_due_cents" => 0,
               "outstanding_deposit_cents" => 0
             } = group(conn)

      assert hd(credit(conn)["lots"])["remaining_cents"] == 1_100
      assert hd(credit(conn)["lots"])["expires_on"] == "2027-11-01"
      assert credit(conn)["available_cents"] == 1_100 + issued
      assert ledger(conn)["credit_liability_cents"] == 1_100 + issued
      assert ledger(conn)["cash_refunded_cents"] == refunded
      assert ledger(conn)["cash_converted_to_credit_cents"] == 1_000 + 505 - refunded
      assert ledger(conn)["cash_held_cents"] == 0
    end
  end

  test "expiry pauses while redeemed and expired restoration removes only the expired portion", %{
    conn: conn
  } do
    issue(conn, "expired", 100)
    issue(conn, "valid", 100, "2026-11-10")

    submit(conn, [
      open_group(%{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-04"}),
      credit_payment(%{"amount_cents" => 150, "occurred_on" => "2027-11-01"})
    ])

    assert ledger(conn, "2027-11-02")["credit_liability_cents"] == 220
    assert credit(conn, "2027-11-02")["available_cents"] == 70

    assert [%{"credit_issued_cents" => 0}] =
             submit(conn, [cancellation(%{"occurred_on" => "2027-11-02"})])

    assert credit(conn, "2027-11-02")["available_cents"] == 110
    assert ledger(conn, "2027-11-02")["credit_liability_cents"] == 110
    assert ledger(conn, "2027-11-11")["credit_liability_cents"] == 0

    assert credit(conn, "2026-11-01")["lots"] |> Enum.map(& &1["source_operation_id"]) == [
             "valid"
           ]
  end

  test "credit restored on its expiry date is available through that day", %{conn: conn} do
    issue(conn, "source", 100)

    submit(conn, [
      open_group(%{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-04"}),
      credit_payment(%{"amount_cents" => 110}),
      cancellation(%{"occurred_on" => "2027-11-01"})
    ])

    assert credit(conn, "2027-11-01")["available_cents"] == 110
    assert credit(conn, "2027-11-02")["available_cents"] == 0
  end

  test "non-refundable mixed cancellation retains cash and consumes credit", %{conn: conn} do
    issue(conn, "source", 1_000)

    submit(conn, [
      open_group(%{"rate_plan" => "advance_purchase"}),
      payment(%{"amount_cents" => 505}),
      credit_payment(%{"amount_cents" => 600})
    ])

    before = snapshot()

    assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
             submit(conn, [
               cancellation(%{"refund_method" => "hotel_credit", "expected_revision" => 2})
             ])

    assert [%{"code" => "refund_method_not_available"}] =
             submit(conn, [
               cancellation(%{"refund_method" => "hotel_credit", "expected_revision" => 3})
             ])

    assert snapshot() == before

    assert [%{"refunded_cents" => 0, "retained_cents" => 505, "credit_issued_cents" => 0}] =
             submit(conn, [cancellation(%{"expected_revision" => 3})])

    assert credit(conn)["available_cents"] == 500
    assert ledger(conn)["credit_liability_cents"] == 500
    assert ledger(conn)["cash_retained_cents"] == 505
    assert ledger(conn)["cash_converted_to_credit_cents"] == 1_000
  end

  test "late flexible cancellation cannot issue credit, including when unpaid", %{conn: conn} do
    submit(conn, [open_group()])
    before = snapshot()

    assert [%{"code" => "refund_method_not_available"}] =
             submit(conn, [
               cancellation(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
             ])

    assert snapshot() == before

    assert [%{"credit_issued_cents" => 0}] =
             submit(conn, [cancellation(%{"refund_method" => "hotel_credit"})])

    assert Repo.all(Lot) == []
  end

  test "invalid refund methods reject atomically, after the revision check", %{conn: conn} do
    issue(conn, "source", 1_000)
    submit(conn, [open_group(), payment(), credit_payment()])
    before = snapshot()

    for method <- [nil, "voucher", 1, [], %{}] do
      assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
               submit(conn, [
                 cancellation(%{"refund_method" => method, "expected_revision" => 2})
               ])

      assert [%{"code" => "invalid_operation"}] =
               submit(conn, [cancellation(%{"refund_method" => method})])

      assert snapshot() == before
    end
  end

  test "credit validation and insufficient funds leave all accounts and revisions unchanged", %{
    conn: conn
  } do
    issue(conn, "source", 100)
    issue(conn, "other-guest", 1_000, "2026-11-01", "another-guest")
    submit(conn, [open_group()])
    before = snapshot()

    for {amount, code} <- [
          {0, "invalid_amount"},
          {-1, "invalid_amount"},
          {1.0, "invalid_amount"},
          {"10", "invalid_amount"},
          {nil, "invalid_amount"},
          {true, "invalid_amount"},
          {[], "invalid_amount"},
          {%{}, "invalid_amount"},
          {19_501, "payment_exceeds_outstanding"},
          {111, "insufficient_credit"}
        ] do
      assert [%{"code" => ^code}] = submit(conn, [credit_payment(%{"amount_cents" => amount})])
      assert snapshot() == before
    end

    assert [%{"code" => "invalid_operation"}] =
             submit(conn, [Map.delete(credit_payment(), "amount_cents")])

    assert [%{"code" => "insufficient_credit"}] =
             submit(conn, [credit_payment(%{"amount_cents" => 1, "occurred_on" => "2027-11-02"})])

    assert snapshot() == before

    assert [%{"revision" => 2}, %{"code" => "stale_revision"}, %{"revision" => 3}] =
             submit(conn, [
               credit_payment(%{"amount_cents" => 100, "expected_revision" => 1}),
               credit_payment(%{"amount_cents" => 100, "expected_revision" => 1}),
               credit_payment(%{"amount_cents" => 10, "expected_revision" => 2})
             ])

    assert credit(conn)["lots"] == []
    assert group(conn)["credit_paid_cents"] == 110
  end

  test "credit and cash share the outstanding limit and later batch operations see settlements",
       %{
         conn: conn
       } do
    results =
      submit(conn, [
        open_group(%{"group_id" => "source"}),
        payment(%{"group_id" => "source", "amount_cents" => 1_000}),
        cancellation(%{"group_id" => "source", "refund_method" => "hotel_credit"}),
        open_group(),
        payment(%{"amount_cents" => 18_500}),
        credit_payment(%{"amount_cents" => 1_001}),
        credit_payment(),
        payment(%{"amount_cents" => 1}),
        credit_payment(%{"amount_cents" => 1})
      ])

    assert Enum.map(results, &(&1["code"] || &1["status"])) == [
             "applied",
             "applied",
             "applied",
             "applied",
             "applied",
             "payment_exceeds_outstanding",
             "applied",
             "payment_exceeds_outstanding",
             "payment_exceeds_outstanding"
           ]

    assert group(conn)["revision"] == 3
    assert group(conn)["deposit_paid_cents"] == 19_500
    assert ledger(conn)["cash_held_cents"] == 18_500
    assert ledger(conn)["credit_liability_cents"] == 1_100
  end

  test "credit bonuses and combined liability retain integer precision for large accounts", %{
    conn: conn
  } do
    cash = 1_844_674_407_370_955_161
    issued = 2_029_141_848_108_050_677

    for number <- 1..5 do
      id = "large-#{number}"

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"credit_issued_cents" => ^issued}
             ] =
               submit(conn, [
                 open_group(%{
                   "group_id" => id,
                   "departure_on" => "2026-12-11",
                   "rooms" => [
                     %{"room_id" => "large", "nightly_rate_cents" => 9_223_372_036_854_775_807}
                   ]
                 }),
                 payment(%{"group_id" => id, "amount_cents" => cash}),
                 cancellation(%{
                   "group_id" => id,
                   "operation_id" => id,
                   "refund_method" => "hotel_credit"
                 })
               ])
    end

    assert credit(conn)["available_cents"] == 10_145_709_240_540_253_385
    assert ledger(conn)["credit_liability_cents"] == 10_145_709_240_540_253_385
    assert ledger(conn)["cash_converted_to_credit_cents"] == 9_223_372_036_854_775_805
  end

  test "source operation IDs remain correlation values when separate cancellations reuse them", %{
    conn: conn
  } do
    for id <- ["first", "second"] do
      submit(conn, [
        open_group(%{"group_id" => id}),
        payment(%{"group_id" => id}),
        cancellation(%{
          "group_id" => id,
          "operation_id" => " shared-Ä ",
          "refund_method" => "hotel_credit"
        })
      ])
    end

    assert Enum.map(credit(conn)["lots"], & &1["source_operation_id"]) == [
             " shared-Ä ",
             " shared-Ä "
           ]

    assert credit(conn)["available_cents"] == 2_200
    submit(conn, [open_group(), credit_payment(%{"amount_cents" => 2_200}), cancellation()])
    assert credit(conn)["available_cents"] == 2_200
  end

  defp issue(conn, id, cash, on \\ "2026-11-01", guest_id \\ "guest-22") do
    date = Date.from_iso8601!(on)

    assert [%{"status" => "applied"}, %{"status" => "applied"}, result] =
             submit(conn, [
               open_group(%{
                 "group_id" => id,
                 "guest_id" => guest_id,
                 "occurred_on" => on,
                 "arrival_on" => Date.to_iso8601(Date.add(date, 60)),
                 "departure_on" => Date.to_iso8601(Date.add(date, 63))
               }),
               payment(%{"group_id" => id, "amount_cents" => cash, "occurred_on" => on}),
               cancellation(%{
                 "group_id" => id,
                 "operation_id" => id,
                 "occurred_on" => on,
                 "refund_method" => "hotel_credit"
               })
             ])

    assert result["status"] == "applied"
    result
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(conn, path), do: conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  defp group(conn), do: read(conn, "/api/v1/groups/group-81")
  defp ledger(conn, on \\ "2026-11-01"), do: read(conn, "/api/v1/ledger?on=#{on}")

  defp credit(conn, on \\ "2026-11-01", guest_id \\ "guest-22"),
    do:
      read(
        conn,
        "/api/v1/guests/#{URI.encode(guest_id, &URI.char_unreserved?/1)}/credit?on=#{on}"
      )

  defp snapshot do
    {Repo.all(Group), Repo.all(Room), Repo.all(Lot), Repo.all(Application)}
  end
end
