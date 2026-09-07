defmodule GroupStayWeb.PaymentChargebacksTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers

  alias GroupStay.{Operations, Repo}
  alias GroupStay.HotelCredit.{Entitlement, Lot}

  test "chargeback moves every disposition except reduced cash and leaves the original receipt exact",
       %{conn: conn} do
    original = payment(%{"operation_id" => "p", "amount_cents" => 500})
    [_, receipt] = submit(conn, [room_group("group-81", [100, 100, 100, 100, 100]), original])

    submit(conn, [
      reduce_cash("p", 50),
      cancel_rooms(["r1"]),
      cancel_rooms(["r2"], %{"occurred_on" => "2026-11-27"}),
      cancel_rooms(["r3"], %{"refund_method" => "hotel_credit"}),
      cancel_rooms(["r4"], %{"refund_method" => "hotel_credit"})
    ])

    assert statement(conn, "p") == %{
             "payment_operation_id" => "p",
             "original_group_id" => "group-81",
             "recorded_cents" => 500,
             "held_cents" => 50,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 200,
             "reduced_cents" => 50,
             "charged_back_cents" => 0
           }

    chargeback = charge_back("p", %{"expected_revision" => 7})

    assert [
             result = %{
               "charged_back_cents" => 450,
               "revision" => 8,
               "outstanding_deposit_cents" => 100
             }
           ] = submit(conn, [chargeback])

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 50,
             "cash_charged_back_cents" => 450,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    assert statement(conn, "p") == %{
             "payment_operation_id" => "p",
             "original_group_id" => "group-81",
             "recorded_cents" => 500,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 50,
             "charged_back_cents" => 450
           }

    before = domain_snapshot()
    assert submit(conn, [original, chargeback]) == [receipt, result]
    assert domain_snapshot() == before
    assert Operations.get_result("p") == receipt

    assert [%{"code" => "payment_not_chargeable"}, %{"code" => "payment_not_reducible"}] =
             submit(conn, [charge_back("p"), reduce_cash("p", 1)])

    assert [%{"revision" => 9}] = submit(conn, [payment(%{"amount_cents" => 100})])
    assert [%{"refunded_cents" => 100}] = submit(conn, [cancellation()])
    assert ledger(conn)["cash_charged_back_cents"] == 450
    assert ledger(conn)["cash_refunded_cents"] == 100
  end

  test "fully reduced payments cannot be charged back, including under fresh operation IDs", %{
    conn: conn
  } do
    submit(conn, [
      room_group(),
      payment(%{"operation_id" => "p", "amount_cents" => 100}),
      reduce_cash("p", 100)
    ])

    assert [%{"code" => "payment_not_chargeable"}] = submit(conn, [charge_back("p")])
    assert statement(conn, "p")["reduced_cents"] == 100
    assert ledger(conn)["cash_charged_back_cents"] == 0
  end

  test "entitlements telescope with half-cent rounding and are independent for every issued lot",
       %{conn: conn} do
    submit(conn, [
      room_group("group-81", [10, 10]),
      payment(%{"operation_id" => "first", "amount_cents" => 5}),
      payment(%{"operation_id" => "second", "amount_cents" => 10}),
      payment(%{"operation_id" => "third", "amount_cents" => 5}),
      cancel_rooms(["r1"], %{"refund_method" => "hotel_credit"}),
      cancellation(%{"refund_method" => "hotel_credit"})
    ])

    assert Enum.map(Repo.all(Entitlement), & &1.amount_cents) == [6, 5, 6, 5]
    assert credit(conn)["available_cents"] == 22

    assert [%{"charged_back_cents" => 10, "revision" => 7}] =
             submit(conn, [charge_back("second")])

    assert credit(conn)["available_cents"] == 11
    assert ledger(conn)["cash_converted_to_credit_cents"] == 10
    assert ledger(conn)["cash_charged_back_cents"] == 10
    assert statement(conn, "first")["converted_to_credit_cents"] == 5
    submit(conn, [charge_back("first"), charge_back("third")])
    assert credit(conn)["available_cents"] == 0
    assert ledger(conn)["cash_charged_back_cents"] == 20
  end

  test "fungible spending creates shortfall only after remaining credit is exhausted, without revising funded groups",
       %{conn: conn} do
    shared_lot(conn)

    submit(conn, [
      room_group("target", [20, 10, 50]),
      credit_payment(%{"group_id" => "target", "amount_cents" => 80})
    ])

    target = group(conn, "target")
    assert [%{"charged_back_cents" => 50, "revision" => 5}] = submit(conn, [charge_back("first")])
    assert group(conn, "target") == target
    assert credit(conn)["available_cents"] == 0
    assert ledger(conn)["credit_shortfall_cents"] == 25
    assert ledger(conn)["credit_liability_cents"] == 80

    submit(conn, [cancel_rooms(["r1"], %{"group_id" => "target"})])
    assert credit(conn)["available_cents"] == 0
    assert ledger(conn)["credit_shortfall_cents"] == 5
    assert ledger(conn)["credit_liability_cents"] == 60
    # Non-refundable credit consumption changes current exposure, not the
    # uncollected entitlement. Liability falls even though nothing is restored.
    submit(conn, [cancel_rooms(["r3"], %{"group_id" => "target", "occurred_on" => "2026-11-27"})])
    assert ledger(conn)["credit_shortfall_cents"] == 5
    assert ledger(conn)["credit_liability_cents"] == 10
    submit(conn, [cancellation(%{"group_id" => "target"})])
    assert credit(conn)["available_cents"] == 5
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 5
    assert [%Lot{unrecovered_clawback_cents: 0, remaining_cents: 5}] = Repo.all(Lot)
  end

  test "shortfall is capped by each lot's active credit and declines on non-refundable consumption",
       %{conn: conn} do
    shared_lot(conn)

    submit(conn, [
      room_group("target", [30, 30, 50]),
      credit_payment(%{"group_id" => "target", "amount_cents" => 110}),
      charge_back("first"),
      charge_back("second")
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 110

    submit(conn, [
      cancel_rooms(["r1", "r2"], %{"group_id" => "target", "occurred_on" => "2026-11-27"})
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 50
    assert ledger(conn)["credit_liability_cents"] == 50
    assert [%Lot{unrecovered_clawback_cents: 110}] = Repo.all(Lot)
    submit(conn, [cancellation(%{"group_id" => "target", "occurred_on" => "2026-11-27"})])
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  test "shortfall absorption precedes expiry and expired excess never becomes available again", %{
    conn: conn
  } do
    shared_lot(conn)

    submit(conn, [
      room_group("target", [80]),
      credit_payment(%{"group_id" => "target", "amount_cents" => 80}),
      reschedule(%{"group_id" => "target", "new_arrival_on" => "2028-06-01"}),
      charge_back("first")
    ])

    assert ledger(conn, "2027-11-02")["credit_shortfall_cents"] == 25
    assert ledger(conn, "2027-11-02")["credit_liability_cents"] == 80
    submit(conn, [cancellation(%{"group_id" => "target", "occurred_on" => "2027-11-02"})])
    assert [%Lot{unrecovered_clawback_cents: 0, remaining_cents: 0}] = Repo.all(Lot)
    assert credit(conn)["available_cents"] == 0
    assert ledger(conn, "2027-11-02")["credit_liability_cents"] == 0
    assert ledger(conn)["credit_shortfall_cents"] == 0
  end

  test "clawbacks remain per lot when a guest has unrelated available credit", %{conn: conn} do
    shared_lot(conn)

    submit(conn, [
      room_group("target", [110]),
      credit_payment(%{"group_id" => "target", "amount_cents" => 110}),
      room_group("unrelated", [100]),
      payment(%{"group_id" => "unrelated", "amount_cents" => 100}),
      cancellation(%{"group_id" => "unrelated", "refund_method" => "hotel_credit"}),
      charge_back("first")
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 55
    assert ledger(conn)["credit_liability_cents"] == 220
    assert credit(conn)["available_cents"] == 110
  end

  test "applied credit operations never become cash correction targets", %{conn: conn} do
    shared_lot(conn)
    credit_payment = credit_payment(%{"group_id" => "target", "amount_cents" => 100})
    submit(conn, [room_group("target"), credit_payment])
    id = credit_payment["operation_id"]
    before = domain_snapshot()

    assert [%{"code" => "payment_not_chargeable"}, %{"code" => "payment_not_reducible"}] =
             submit(conn, [charge_back(id), reduce_cash(id, 1)])

    assert conn |> get("/api/v1/payments/#{id}") |> json_response(422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }

    assert domain_snapshot() == before
  end

  defp shared_lot(conn) do
    submit(conn, [
      room_group("group-81", [100]),
      payment(%{"operation_id" => "first", "amount_cents" => 50}),
      payment(%{"operation_id" => "second", "amount_cents" => 50}),
      cancellation(%{"refund_method" => "hotel_credit"})
    ])
  end

  defp submit(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp read(conn, path), do: conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  defp group(conn, id), do: read(conn, "/api/v1/groups/#{id}")
  defp ledger(conn, on \\ "2026-11-01"), do: read(conn, "/api/v1/ledger?on=#{on}")
  defp credit(conn), do: read(conn, "/api/v1/guests/guest-22/credit?on=2026-11-01")
  defp statement(conn, id), do: read(conn, "/api/v1/payments/#{id}")
end
