defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers

  alias GroupStay.{Operations, Repo}
  alias GroupStay.HotelCredit.Lot

  test "cash and credit fill rooms in submission order and selected settlement leaves other allocations intact",
       %{conn: conn} do
    submit(conn, [
      room_group("source", [200]),
      payment(%{"group_id" => "source", "amount_cents" => 100}),
      cancellation(%{"group_id" => "source", "refund_method" => "hotel_credit"}),
      room_group(),
      payment(%{"operation_id" => "p1", "amount_cents" => 150}),
      credit_payment(%{"amount_cents" => 110, "occurred_on" => "2026-11-02"}),
      payment(%{"operation_id" => "p2", "amount_cents" => 25, "occurred_on" => "2026-10-01"})
    ])

    assert amounts(conn) == [{100, 0}, {50, 50}, {25, 60}]
    operation = cancel_rooms(["r3", "r1"], %{"expected_revision" => 4})
    [result] = submit(conn, [operation])

    assert result == %{
             "operation_id" => operation["operation_id"],
             "status" => "applied",
             "group_id" => "group-81",
             "cancelled_room_ids" => ["r1", "r3"],
             "refunded_cents" => 125,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 5
           }

    assert amounts(conn) == [{0, 0}, {50, 50}, {0, 0}]

    assert Map.take(
             group(conn),
             ~w(status lodging_total_cents deposit_due_cents deposit_paid_cents outstanding_deposit_cents)
           ) == %{
             "status" => "active",
             "lodging_total_cents" => 500,
             "deposit_due_cents" => 100,
             "deposit_paid_cents" => 100,
             "outstanding_deposit_cents" => 0
           }

    assert credit(conn)["available_cents"] == 60
    assert statement(conn, "p1")["refunded_cents"] == 100
    assert statement(conn, "p1")["held_cents"] == 50
    assert statement(conn, "p2")["refunded_cents"] == 25
    assert [%{"refunded_cents" => 50, "revision" => 6}] = submit(conn, [cancellation()])
    assert group(conn)["status"] == "cancelled"
    assert group(conn)["deposit_paid_cents"] == 0
    assert credit(conn)["available_cents"] == 110
    assert ledger(conn)["cash_refunded_cents"] == 175
    assert ledger(conn)["credit_liability_cents"] == 110
    before = domain_snapshot()
    assert submit(conn, [operation]) == [result]
    assert domain_snapshot() == before
  end

  test "one bonus is calculated for the selected cash and repeated partial cancellations issue independent lots",
       %{conn: conn} do
    submit(conn, [
      room_group("group-81", [5, 5, 5]),
      payment(%{"operation_id" => "p", "amount_cents" => 15})
    ])

    assert [%{"credit_issued_cents" => 11, "cancelled_room_ids" => ["r1", "r2"]}] =
             submit(conn, [cancel_rooms(["r2", "r1"], %{"refund_method" => "hotel_credit"})])

    assert [%{"credit_issued_cents" => 6}] =
             submit(conn, [cancellation(%{"refund_method" => "hotel_credit"})])

    assert Repo.aggregate(Lot, :count) == 2
    assert credit(conn)["available_cents"] == 17
    assert statement(conn, "p")["converted_to_credit_cents"] == 15
    submit(conn, [charge_back("p")])
    assert credit(conn)["available_cents"] == 0
    assert ledger(conn)["cash_charged_back_cents"] == 15
  end

  for ids <- [[], nil, "r1", %{}, ["r1", "r1"], ["missing"], ["r1", "missing"], [nil], [1]] do
    test "invalid room selection #{inspect(ids)} is atomic and durable", %{conn: conn} do
      submit(conn, [room_group(), payment(%{"amount_cents" => 150})])
      before = domain_snapshot()
      invalid = cancel_rooms(unquote(Macro.escape(ids)))
      assert [%{"code" => "invalid_rooms"} = result] = submit(conn, [invalid])
      assert domain_snapshot() == before
      assert [%{"revision" => 3}] = submit(conn, [cancel_rooms(["r1"])])
      assert submit(conn, [invalid]) == [result]
      assert [%{"code" => "invalid_rooms"}] = submit(conn, [cancel_rooms(["r1", "r2"])])
      assert [%{"revision" => 4}] = submit(conn, [cancel_rooms(["r2", "r3"])])
      assert group(conn)["status"] == "cancelled"
    end
  end

  test "room cancellation checks group and revision before selection, date and refund availability",
       %{conn: conn} do
    assert [%{"code" => "group_not_found"}] =
             submit(conn, [cancel_rooms([], %{"expected_revision" => 9})])

    submit(conn, [room_group()])

    assert [%{"code" => "stale_revision", "actual_revision" => 1}] =
             submit(conn, [
               cancel_rooms([], %{
                 "expected_revision" => 9,
                 "occurred_on" => "invalid",
                 "refund_method" => "invalid"
               })
             ])

    assert [%{"code" => "refund_method_not_available"}, %{"revision" => 2, "retained_cents" => 0}] =
             submit(conn, [
               cancel_rooms(["r1"], %{
                 "occurred_on" => "2026-11-27",
                 "refund_method" => "hotel_credit"
               }),
               cancel_rooms(["r1"], %{"occurred_on" => "2026-11-27", "expected_revision" => 1})
             ])

    assert group(conn)["deposit_due_cents"] == 200
  end

  test "partial cancellation uses the fixed policy and rescheduled boundary", %{conn: conn} do
    submit(conn, [
      room_group("group-81", [100, 100], %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02"
      }),
      payment(%{"amount_cents" => 200}),
      reschedule(%{"new_arrival_on" => "2028-06-01"})
    ])

    assert [%{"refunded_cents" => 100}] =
             submit(conn, [cancel_rooms(["r1"], %{"occurred_on" => "2028-05-02"})])

    assert [%{"retained_cents" => 100}] =
             submit(conn, [cancellation(%{"occurred_on" => "2028-05-03"})])

    assert group(conn)["policy_version"] == "flex-30"
  end

  test "new operation envelopes require their identifying fields and derive the payment group", %{
    conn: conn
  } do
    submit(conn, [room_group(), payment(%{"operation_id" => "p", "amount_cents" => 100})])

    invalid = [
      Map.delete(cancel_rooms(["r1"]), "room_ids"),
      Map.delete(reduce_cash("p", 1), "payment_operation_id"),
      Map.delete(reduce_cash("p", 1), "amount_cents"),
      Map.delete(charge_back("p"), "payment_operation_id"),
      charge_back(nil),
      reduce_cash("", 1),
      charge_back("p", %{"occurred_on" => "bad"})
    ]

    before = domain_snapshot()
    assert Enum.all?(submit(conn, invalid), &(&1["code"] == "invalid_operation"))
    assert domain_snapshot() == before

    correction =
      reduce_cash("p", 50, %{"expected_revision" => 2})
      |> Map.put("group_id", "not-the-payment-group")

    assert [%{"group_id" => "group-81", "revision" => 3}] = submit(conn, [correction])
  end

  test "reductions remove only the target's held allocations in reverse fill order and reopen gaps",
       %{conn: conn} do
    original = payment(%{"operation_id" => "p1", "amount_cents" => 150})

    [_, paid, _] =
      submit(conn, [
        room_group(),
        original,
        payment(%{"operation_id" => "p2", "amount_cents" => 100})
      ])

    reduction = reduce_cash("p1", 75, %{"expected_revision" => 3})

    assert [
             %{
               "amount_cents" => 75,
               "outstanding_deposit_cents" => 125,
               "revision" => 4,
               "group_id" => "group-81",
               "payment_operation_id" => "p1"
             }
           ] = submit(conn, [reduction])

    assert amounts(conn) == [{75, 0}, {50, 0}, {50, 0}]
    assert statement(conn, "p1")["reduced_cents"] == 75
    assert statement(conn, "p2")["held_cents"] == 100
    submit(conn, [payment(%{"operation_id" => "p3", "amount_cents" => 40})])
    assert amounts(conn) == [{100, 0}, {65, 0}, {50, 0}]
    assert [%{"refunded_cents" => 65}] = submit(conn, [cancel_rooms(["r2"])])

    assert [
             %{"code" => "reduction_exceeds_held_cash"},
             %{"amount_cents" => 75},
             %{"code" => "payment_not_reducible"}
           ] =
             submit(conn, [reduce_cash("p1", 76), reduce_cash("p1", 75), reduce_cash("p1", 1)])

    assert amounts(conn) == [{25, 0}, {0, 0}, {50, 0}]
    assert ledger(conn)["cash_reduced_cents"] == 150
    assert submit(conn, [original]) == [paid]
    assert Operations.get_result("p1") == paid
    assert statement(conn, "p1")["recorded_cents"] == 150
    assert statement(conn, "p1")["held_cents"] == 0
  end

  for amount <- [0, -1, nil, true, "10", 1.0, [], %{}] do
    test "unusable reduction #{inspect(amount)} cannot change accounting", %{conn: conn} do
      submit(conn, [room_group(), payment(%{"operation_id" => "p", "amount_cents" => 100})])
      before = domain_snapshot()

      assert [%{"code" => "invalid_amount"}] =
               submit(conn, [reduce_cash("p", unquote(Macro.escape(amount)))])

      assert domain_snapshot() == before
    end
  end

  test "payment corrections resolve durable identity and stale revision before amount or held cash rules",
       %{conn: conn} do
    submit(conn, [room_group(), payment(%{"operation_id" => "p", "amount_cents" => 100})])
    submit(conn, [cancellation()])

    for correction <- [
          reduce_cash("p", -1, %{"expected_revision" => 1}),
          charge_back("p", %{"expected_revision" => 1})
        ] do
      assert [%{"code" => "stale_revision", "actual_revision" => 3, "group_id" => "group-81"}] =
               submit(conn, [correction])
    end

    assert [%{"code" => "payment_not_reducible"}] = submit(conn, [reduce_cash("p", -1)])
    assert [%{"charged_back_cents" => 100, "revision" => 4}] = submit(conn, [charge_back("p")])
    assert [%{"code" => "payment_not_chargeable"}] = submit(conn, [charge_back("p")])

    for correction <- [reduce_cash("legacy", 1), charge_back("legacy")] do
      assert [%{"code" => "operation_not_found"}] = submit(conn, [correction])
    end
  end

  test "statements expose exactly current dispositions and reject noncash or rejected targets", %{
    conn: conn
  } do
    opening = room_group()
    invalid = payment(%{"amount_cents" => -1})
    credit_attempt = credit_payment()

    submit(conn, [
      opening,
      invalid,
      credit_attempt,
      payment(%{"operation_id" => " Pay-Ä ?# ", "amount_cents" => 100})
    ])

    before = domain_snapshot()

    assert statement(conn, " Pay-Ä ?# ") == %{
             "payment_operation_id" => " Pay-Ä ?# ",
             "original_group_id" => "group-81",
             "recorded_cents" => 100,
             "held_cents" => 100,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }

    assert domain_snapshot() == before

    assert conn |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    for target <- [opening, invalid, credit_attempt] do
      id = target["operation_id"]

      assert conn |> get("/api/v1/payments/#{id}") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }

      assert [%{"code" => "payment_not_reducible"}, %{"code" => "payment_not_chargeable"}] =
               submit(conn, [reduce_cash(id, 1), charge_back(id)])
    end
  end

  defp submit(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp read(conn, path), do: conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  defp group(conn), do: read(conn, "/api/v1/groups/group-81")

  defp amounts(conn),
    do: Enum.map(group(conn)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp ledger(conn), do: read(conn, "/api/v1/ledger?on=2026-11-01")
  defp credit(conn), do: read(conn, "/api/v1/guests/guest-22/credit?on=2026-11-01")

  defp statement(conn, id),
    do: read(conn, "/api/v1/payments/#{URI.encode(id, &URI.char_unreserved?/1)}")
end
