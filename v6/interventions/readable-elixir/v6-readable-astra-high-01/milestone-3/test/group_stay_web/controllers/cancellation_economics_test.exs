defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase
  import GroupStay.OperationFixtures

  alias GroupStay.{Credits, Repo, Reservations}
  alias GroupStay.Credits.{Allocation, Lot}
  alias GroupStay.Reservations.Group

  test "policy is selected at booking and stays fixed when rescheduled", %{conn: conn} do
    for {id, booked, plan, policy, deadline} <- [
          {"old", "2026-12-31", "flexible", "flex-14", "2027-02-15"},
          {"new", "2027-01-01", "flexible", "flex-30", "2027-01-30"},
          {"advance", "2027-01-01", "advance_purchase", "advance-nonrefundable", nil}
        ] do
      apply!(
        open_operation(%{
          "group_id" => id,
          "occurred_on" => booked,
          "rate_plan" => plan,
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        })
      )

      assert %{"policy_version" => ^policy, "refundable_until" => ^deadline} = group(conn, id)

      result =
        apply!(
          operation("reschedule_group", %{
            "group_id" => id,
            "occurred_on" => "2027-01-05",
            "new_arrival_on" => "2028-03-01"
          })
        )

      assert result.policy_version == policy
      assert result.new_departure_on == ~D[2028-03-04]

      expected =
        case policy do
          "flex-14" -> ~D[2028-02-16]
          "flex-30" -> ~D[2028-01-31]
          _ -> nil
        end

      assert result.refundable_until == expected
      assert group(conn, id)["policy_version"] == policy
    end
  end

  test "new flexible policy refunds on the 30-day boundary and retains the next day" do
    for {id, date, refunded, retained} <- [
          {"boundary", "2027-01-30", 105, 0},
          {"late", "2027-01-31", 0, 105}
        ] do
      apply!(
        open_operation(%{
          "group_id" => id,
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        })
      )

      apply!(operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 105}))
      result = apply!(operation("cancel_group", %{"group_id" => id, "occurred_on" => date}))
      assert result.refunded_cents == refunded
      assert result.retained_cents == retained
      assert result.credit_issued_cents == 0
    end
  end

  test "cash conversion rounds the bonus half up, exposes lots and expires after day 365", %{
    conn: conn
  } do
    issue_credit("source", " Cancel-é ", 105, "2026-10-04")

    assert credit(conn, "2027-10-04") == %{
             "guest_id" => "guest-22",
             "available_cents" => 116,
             "lots" => [
               %{
                 "source_operation_id" => " Cancel-é ",
                 "remaining_cents" => 116,
                 "expires_on" => "2027-10-04"
               }
             ]
           }

    assert credit(conn, "2027-10-05")["lots"] == []

    assert ledger(conn, "2027-10-04") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 105,
             "credit_liability_cents" => 116
           }

    assert ledger(conn, "2027-10-05")["credit_liability_cents"] == 0
    assert group(conn, "source")["cash_paid_cents"] == 0
    assert group(conn, "source")["credit_paid_cents"] == 0

    issue_credit("round-down", "round-down", 104, "2026-10-04")
    assert credit(conn, "2026-10-04")["available_cents"] == 230
  end

  test "late flexible cancellation cannot select credit or bypass a stale revision" do
    apply!(open_operation())
    apply!(operation("record_cash_payment", %{"amount_cents" => 100}))
    before = snapshot()

    assert [%{code: "stale_revision", actual_revision: 2}, %{code: "refund_method_not_available"}] =
             Reservations.process_batch([
               operation("cancel_group", %{
                 "occurred_on" => "2026-11-27",
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 1
               }),
               operation("cancel_group", %{
                 "occurred_on" => "2026-11-27",
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 2
               })
             ])

    assert snapshot() == before

    assert %{retained_cents: 100, revision: 3} =
             apply!(operation("cancel_group", %{"occurred_on" => "2026-11-27"}))
  end

  test "zero cash does not issue an empty lot" do
    apply!(open_operation())

    assert %{credit_issued_cents: 0, revision: 2} =
             apply!(operation("cancel_group", %{"refund_method" => "hotel_credit"}))

    assert Repo.all(Lot) == []
  end

  test "credit consumes earliest expiry then source identifier and restores original lots", %{
    conn: conn
  } do
    issue_credit("b", "b", 100, "2026-10-05")
    issue_credit("a", "a", 100, "2026-10-05")
    issue_credit("z", "z", 100, "2026-10-04")
    apply!(open_operation())

    assert %{amount_cents: 150, outstanding_deposit_cents: 19_350, revision: 2} =
             apply!(
               operation("apply_hotel_credit", %{
                 "amount_cents" => 150,
                 "occurred_on" => "2026-10-06"
               })
             )

    assert credit(conn, "2026-10-06")["lots"] == [
             %{
               "source_operation_id" => "a",
               "remaining_cents" => 70,
               "expires_on" => "2027-10-05"
             },
             %{
               "source_operation_id" => "b",
               "remaining_cents" => 110,
               "expires_on" => "2027-10-05"
             }
           ]

    assert %{"deposit_paid_cents" => 150, "cash_paid_cents" => 0, "credit_paid_cents" => 150} =
             group(conn, "group-81")

    assert ledger(conn, "2026-10-06")["credit_liability_cents"] == 330
    assert ledger(conn, "2026-10-06")["cash_held_cents"] == 0

    # Repeated redemption from the same lot must restore every allocation.
    apply!(
      operation("apply_hotel_credit", %{"amount_cents" => 20, "occurred_on" => "2026-10-06"})
    )

    assert %{credit_issued_cents: 0, refunded_cents: 0, retained_cents: 0, revision: 4} =
             apply!(
               operation("cancel_group", %{
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2026-10-07"
               })
             )

    lots = credit(conn, "2026-10-07")["lots"]
    assert Enum.map(lots, & &1["source_operation_id"]) == ["z", "a", "b"]
    assert Enum.map(lots, & &1["remaining_cents"]) == [110, 110, 110]
    assert Repo.all(Allocation) == []
  end

  test "mixed funding returns applied credit without a second bonus for either refund method", %{
    conn: conn
  } do
    for method <- ["cash", "hotel_credit"] do
      guest = "guest-#{method}"
      issue_credit("source-#{method}", "source-#{method}", 500, "2026-10-04", guest)
      apply!(open_operation(%{"group_id" => method, "guest_id" => guest}))
      apply!(operation("apply_hotel_credit", %{"group_id" => method, "amount_cents" => 400}))
      apply!(operation("record_cash_payment", %{"group_id" => method, "amount_cents" => 105}))

      assert %{"cash_paid_cents" => 105, "credit_paid_cents" => 400, "deposit_paid_cents" => 505} =
               group(conn, method)

      result =
        apply!(
          operation("cancel_group", %{
            "group_id" => method,
            "operation_id" => "settle-#{method}",
            "refund_method" => method
          })
        )

      assert result.refunded_cents == if(method == "cash", do: 105, else: 0)
      assert result.credit_issued_cents == if(method == "cash", do: 0, else: 116)
      assert result.retained_cents == 0

      assert Credits.for_guest(guest, ~D[2026-10-04]).available_cents ==
               if(method == "cash", do: 550, else: 666)
    end

    assert Reservations.ledger(~D[2026-10-04]) == %{
             cash_held_cents: 0,
             cash_refunded_cents: 105,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 1105,
             credit_liability_cents: 1216
           }
  end

  test "expiry pauses while allocated; refundable restoration after expiry consumes only expired allocations" do
    issue_credit("old", "old", 100, "2026-10-04")
    issue_credit("new", "new", 100, "2026-10-06")
    apply!(open_operation(%{"arrival_on" => "2027-12-01", "departure_on" => "2027-12-04"}))

    apply!(
      operation("apply_hotel_credit", %{"amount_cents" => 160, "occurred_on" => "2027-10-04"})
    )

    assert Reservations.ledger(~D[2027-10-05]).credit_liability_cents == 220
    assert Credits.for_guest("guest-22", ~D[2027-10-05]).available_cents == 60
    apply!(operation("cancel_group", %{"occurred_on" => "2027-10-05"}))
    assert Credits.for_guest("guest-22", ~D[2027-10-05]).available_cents == 110
    assert Reservations.ledger(~D[2027-10-05]).credit_liability_cents == 110
    assert Repo.all(Allocation) == []
  end

  test "restoration on expiry day remains available and expires the following day" do
    issue_credit("source", "source", 100, "2026-10-04")
    apply!(open_operation(%{"arrival_on" => "2027-12-01", "departure_on" => "2027-12-04"}))
    apply!(operation("apply_hotel_credit", %{"amount_cents" => 110}))
    apply!(operation("cancel_group", %{"occurred_on" => "2027-10-04"}))
    assert Credits.for_guest("guest-22", ~D[2027-10-04]).available_cents == 110
    assert Reservations.ledger(~D[2027-10-05]).credit_liability_cents == 0
  end

  test "non-refundable cancellation consumes credit and retains only cash" do
    issue_credit("source", "source", 500, "2026-10-04")
    apply!(open_operation(%{"rate_plan" => "advance_purchase"}))
    apply!(operation("apply_hotel_credit", %{"amount_cents" => 400}))
    apply!(operation("record_cash_payment", %{"amount_cents" => 105}))
    before = snapshot()

    assert [%{code: "refund_method_not_available"}] =
             Reservations.process_batch([
               operation("cancel_group", %{
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 3
               })
             ])

    assert snapshot() == before

    assert %{refunded_cents: 0, retained_cents: 105, credit_issued_cents: 0, revision: 4} =
             apply!(operation("cancel_group"))

    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 150
    assert Reservations.ledger(~D[2026-10-04]).cash_retained_cents == 105
    assert Repo.all(Allocation) == []
  end

  test "failed credit and refund operations preserve all balances and revisions, then batch continues" do
    issue_credit("source", "source", 100, "2026-10-04")
    apply!(open_operation())

    for {overrides, code} <- [
          {%{}, "invalid_operation"},
          {%{"amount_cents" => nil}, "invalid_amount"},
          {%{"amount_cents" => 0}, "invalid_amount"},
          {%{"amount_cents" => -1}, "invalid_amount"},
          {%{"amount_cents" => 1.5}, "invalid_amount"},
          {%{"amount_cents" => "1"}, "invalid_amount"},
          {%{"amount_cents" => 19_501}, "payment_exceeds_outstanding"},
          {%{"amount_cents" => 111}, "insufficient_credit"},
          {%{"amount_cents" => 1, "occurred_on" => "2027-10-05"}, "insufficient_credit"}
        ] do
      before = snapshot()

      assert [%{code: ^code}] =
               Reservations.process_batch([operation("apply_hotel_credit", overrides)])

      assert snapshot() == before
    end

    for method <- [nil, "card", 1, false, %{}] do
      before = snapshot()

      assert [%{code: "invalid_operation"}] =
               Reservations.process_batch([
                 operation("cancel_group", %{"refund_method" => method})
               ])

      assert snapshot() == before
    end

    assert [
             %{code: "stale_revision"},
             %{code: "stale_revision"},
             %{revision: 2},
             %{code: "stale_revision"},
             %{revision: 3}
           ] =
             Reservations.process_batch([
               operation("apply_hotel_credit", %{"amount_cents" => 111, "expected_revision" => 9}),
               operation("cancel_group", %{"refund_method" => "bad", "expected_revision" => 9}),
               operation("apply_hotel_credit", %{"amount_cents" => 100, "expected_revision" => 1}),
               operation("cancel_group", %{"expected_revision" => 1}),
               operation("record_cash_payment", %{
                 "amount_cents" => 19_400,
                 "expected_revision" => 2
               })
             ])

    assert Reservations.get_group("group-81").deposit_paid_cents == 19_500
  end

  test "credit belongs to the guest across properties, never another guest" do
    issue_credit("source", "source", 100, "2026-10-04")
    apply!(open_operation(%{"guest_id" => "other"}))

    assert [%{code: "insufficient_credit"}] =
             Reservations.process_batch([
               operation("apply_hotel_credit", %{"amount_cents" => 1})
             ])

    apply!(open_operation(%{"group_id" => "same-guest", "property_id" => "another-property"}))

    assert %{revision: 2} =
             apply!(
               operation("apply_hotel_credit", %{
                 "group_id" => "same-guest",
                 "amount_cents" => 110
               })
             )
  end

  test "dated reads are non-mutating, default to UTC today, and reject invalid dates", %{
    conn: conn
  } do
    issue_credit("source", "source", 100, "2026-10-04")
    before = snapshot()

    for path <- ["/api/v1/ledger", "/api/v1/guests/guest-22/credit"] do
      assert read(conn, path) == read(conn, path <> "?on=#{Date.utc_today()}")

      for query <- ["on=bad", "on=2027-02-29", "on[]=2027-01-01"] do
        assert conn |> get(path <> "?" <> query) |> json_response(422) ==
                 %{"error" => %{"code" => "invalid_date"}}
      end
    end

    assert read(conn, "/api/v1/guests/unknown/credit") ==
             %{"guest_id" => "unknown", "available_cents" => 0, "lots" => []}

    credit(conn, "2030-01-01")
    ledger(conn, "2030-01-01")
    assert snapshot() == before
  end

  test "HTTP batches expose the credit settlement and redemption contract in array order", %{
    conn: conn
  } do
    operations = [
      open_operation(%{"group_id" => "source"}),
      operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 105}),
      operation("cancel_group", %{
        "group_id" => "source",
        "operation_id" => "convert",
        "refund_method" => "hotel_credit"
      }),
      open_operation(),
      operation("apply_hotel_credit", %{"amount_cents" => 117, "expected_revision" => 1}),
      operation("apply_hotel_credit", %{
        "operation_id" => "apply_hotel_credit-1",
        "amount_cents" => 116,
        "expected_revision" => 1
      })
    ]

    results =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
      |> json_response(200)
      |> Map.fetch!("results")

    assert [
             _,
             _,
             %{
               "operation_id" => "convert",
               "status" => "applied",
               "group_id" => "source",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 116,
               "revision" => 3
             },
             _,
             %{"code" => "insufficient_credit"},
             %{
               "operation_id" => "apply_hotel_credit-1",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 116,
               "outstanding_deposit_cents" => 19_384,
               "revision" => 2
             }
           ] = results

    assert credit(conn, "2026-10-04")["lots"] == []
  end

  defp issue_credit(group_id, source, cash, date, guest \\ "guest-22") do
    apply!(open_operation(%{"group_id" => group_id, "guest_id" => guest}))
    apply!(operation("record_cash_payment", %{"group_id" => group_id, "amount_cents" => cash}))

    result =
      apply!(
        operation("cancel_group", %{
          "group_id" => group_id,
          "operation_id" => source,
          "occurred_on" => date,
          "refund_method" => "hotel_credit"
        })
      )

    assert result.refunded_cents == 0
    assert result.retained_cents == 0
    result
  end

  defp apply!(operation) do
    assert [%{status: "applied"} = result] = Reservations.process_batch([operation])
    result
  end

  defp snapshot, do: {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation)}
  defp group(conn, id), do: read(conn, "/api/v1/groups/#{id}")
  defp credit(conn, on), do: read(conn, "/api/v1/guests/guest-22/credit?on=#{on}")
  defp ledger(conn, on), do: read(conn, "/api/v1/ledger?on=#{on}")
  defp read(conn, path), do: conn |> get(path) |> json_response(200) |> Map.fetch!("data")
end
