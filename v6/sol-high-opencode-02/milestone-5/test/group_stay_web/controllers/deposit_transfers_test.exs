defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Bookings.{CashAllocation, CashSource, CreditAllocation, Room}
  alias GroupStay.Repo

  test "moves mixed funding in reverse allocation order and replays exactly", %{conn: conn} do
    assert_all_applied(conn, credit_lot_operations())

    setup = [
      open_group("source", "open-source", [100, 100]),
      apply_credit("source", "credit-source", 60),
      payment("source", "pay-old", 90),
      payment("source", "pay-new", 50),
      open_group("destination", "open-destination", [100, 100])
    ]

    assert_all_applied(build_conn(), setup)

    assert %{"data" => old_statement} = payment_statement("pay-old")
    refute Map.has_key?(old_statement, "held_by_group")

    ledger_before = ledger()

    transfer = transfer("move-mixed", "source", "destination", 180, 4, 1)
    assert %{"results" => [result]} = submit(build_conn(), [transfer])

    assert result == %{
             "operation_id" => "move-mixed",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 180,
             "source_outstanding_deposit_cents" => 180,
             "destination_outstanding_deposit_cents" => 20,
             "source_revision" => 5,
             "destination_revision" => 2
           }

    assert group_funding("source") == {180, 0, 20, 5}
    assert group_funding("destination") == {20, 140, 40, 2}
    assert ledger() == ledger_before

    assert cash_allocations("destination") == [
             {"room-1", "pay-new", 50},
             {"room-1", "pay-old", 50},
             {"room-2", "pay-old", 40}
           ]

    assert credit_allocations("destination") == [{"room-2", "issue-credit", 40}]

    assert %{
             "data" => %{
               "held_cents" => 90,
               "held_by_group" => [%{"group_id" => "destination", "amount_cents" => 90}]
             }
           } = payment_statement("pay-old")

    assert %{
             "data" => %{
               "held_cents" => 50,
               "held_by_group" => [%{"group_id" => "destination", "amount_cents" => 50}]
             }
           } = payment_statement("pay-new")

    assert %{"results" => [^result]} = submit(build_conn(), [transfer])
    assert group_funding("source") == {180, 0, 20, 5}
    assert group_funding("destination") == {20, 140, 40, 2}
  end

  test "uses source and destination resolution and revision precedence", %{conn: conn} do
    assert_all_applied(conn, [
      open_group("source", "open-source", [100]),
      payment("source", "pay-source", 50),
      open_group("destination", "open-destination", [100]),
      open_group("other-guest", "open-other", [100], "guest-2")
    ])

    operations = [
      transfer("missing-source", "missing-a", "missing-b", 1),
      transfer("missing-destination", "source", "missing-b", 1),
      transfer("stale-source", "source", "destination", 0, 1, 0),
      transfer("stale-destination", "source", "destination", 0, 2, 0),
      transfer("same-group", "source", "source", 1, 2, 2),
      transfer("other-guest", "source", "other-guest", 1),
      transfer("invalid-amount", "source", "destination", 0),
      transfer("too-much-held", "source", "destination", 51),
      transfer("too-much-outstanding", "source", "destination", 101)
    ]

    assert %{"results" => results} = submit(build_conn(), operations)

    assert Enum.map(results, & &1["code"]) == [
             "group_not_found",
             "group_not_found",
             "stale_revision",
             "stale_revision",
             "invalid_transfer",
             "invalid_transfer",
             "invalid_amount",
             "transfer_exceeds_held_funding",
             "transfer_exceeds_held_funding"
           ]

    assert Enum.at(results, 0)["group_id"] == "missing-a"
    assert Enum.at(results, 1)["group_id"] == "missing-b"
    assert Enum.at(results, 2)["group_id"] == "source"
    assert Enum.at(results, 2)["actual_revision"] == 2
    assert Enum.at(results, 3)["group_id"] == "destination"
    assert group_funding("source") == {50, 50, 0, 2}
    assert group_funding("destination") == {100, 0, 0, 1}

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(build_conn(), [payment("destination", "fill-destination", 100)])

    assert %{"results" => [%{"code" => "transfer_exceeds_outstanding"}]} =
             submit(build_conn(), [transfer("full-destination", "source", "destination", 1)])

    assert_all_applied(build_conn(), [cancel("destination", "cancel-destination", "2027-01-10")])

    assert %{"results" => [%{"code" => "group_not_active", "group_id" => "destination"}]} =
             submit(build_conn(), [transfer("inactive-destination", "source", "destination", 1)])
  end

  test "reductions follow transferred cash and revise every changed group", %{conn: conn} do
    assert_all_applied(conn, [
      open_group("source", "open-source", [100]),
      payment("source", "pay-source", 100),
      open_group("destination", "open-destination", [100]),
      transfer("move-cash", "source", "destination", 70, 2, 1)
    ])

    reduction = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-01-05",
      "payment_operation_id" => "pay-source",
      "amount_cents" => 80,
      "expected_revision" => 3
    }

    assert %{"results" => [result]} = submit(build_conn(), [reduction])
    assert result["status"] == "applied"
    assert result["revision"] == 4
    assert result["outstanding_deposit_cents"] == 80
    assert group_funding("source") == {80, 20, 0, 4}
    assert group_funding("destination") == {100, 0, 0, 3}

    assert %{
             "data" => %{
               "held_cents" => 20,
               "held_by_group" => [%{"group_id" => "source", "amount_cents" => 20}]
             }
           } = payment_statement("pay-source")
  end

  test "transferred cash uses the destination policy and converted credit is chargeable",
       %{conn: conn} do
    assert_all_applied(conn, [
      open_group("source", "open-source", [100], "guest-1", "advance_purchase"),
      payment("source", "pay-source", 100),
      open_group("destination", "open-destination", [100]),
      transfer("move-cash", "source", "destination", 60),
      cancel("destination", "cancel-destination", "2027-01-10")
      |> Map.put("refund_method", "hotel_credit")
    ])

    assert %{
             "data" => %{
               "cash_converted_to_credit_cents" => 60,
               "cash_held_cents" => 40,
               "credit_liability_cents" => 66
             }
           } = ledger()

    assert group_revision("source") == 3
    assert group_revision("destination") == 3

    chargeback = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-11",
      "payment_operation_id" => "pay-source",
      "expected_revision" => 3
    }

    assert %{"results" => [result]} = submit(build_conn(), [chargeback])
    assert result["charged_back_cents"] == 100
    assert result["revision"] == 4
    assert group_funding("source") == {100, 0, 0, 4}
    assert group_revision("destination") == 4

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 100,
               "credit_liability_cents" => 0
             }
           } = ledger()

    assert %{"data" => %{"held_by_group" => []}} = payment_statement("pay-source")
  end

  test "transferred credit keeps its lot and restores without a second bonus", %{conn: conn} do
    assert_all_applied(conn, credit_lot_operations())

    assert_all_applied(build_conn(), [
      open_group("source", "open-source", [100]),
      apply_credit("source", "apply-source", 100),
      open_group("destination", "open-destination", [100]),
      transfer("move-credit", "source", "destination", 60),
      cancel("destination", "cancel-destination", "2027-01-10")
    ])

    assert group_funding("source") == {60, 0, 40, 3}

    assert %{
             "data" => %{
               "available_cents" => 70,
               "lots" => [%{"source_operation_id" => "issue-credit", "remaining_cents" => 70}]
             }
           } =
             get(build_conn(), "/api/v1/guests/guest-1/credit?on=2027-01-10")
             |> json_response(200)

    assert %{
             "data" => %{
               "cash_converted_to_credit_cents" => 100,
               "credit_liability_cents" => 110
             }
           } = ledger()
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)
  end

  defp assert_all_applied(conn, operations) do
    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
  end

  defp open_group(
         group_id,
         operation_id,
         room_deposits,
         guest_id \\ "guest-1",
         rate_plan \\ "flexible"
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => rate_plan,
      "rooms" =>
        room_deposits
        |> Enum.with_index(1)
        |> Enum.map(fn {deposit, position} ->
          rate = if rate_plan == "flexible", do: deposit * 5, else: deposit
          %{"room_id" => "room-#{position}", "nightly_rate_cents" => rate}
        end)
    }
  end

  defp payment(group_id, operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp apply_credit(group_id, operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-03",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(
         operation_id,
         source,
         destination,
         amount,
         source_revision \\ nil,
         dest_revision \\ nil
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2027-01-04",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
    |> maybe_put("expected_revision", source_revision)
    |> maybe_put("destination_expected_revision", dest_revision)
  end

  defp cancel(group_id, operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp credit_lot_operations do
    [
      open_group("credit-origin", "open-credit-origin", [100]),
      payment("credit-origin", "credit-principal", 100),
      %{
        "operation_id" => "issue-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "credit-origin",
        "refund_method" => "hotel_credit"
      }
    ]
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp group_funding(group_id) do
    assert %{
             "data" => %{
               "outstanding_deposit_cents" => outstanding,
               "cash_paid_cents" => cash,
               "credit_paid_cents" => credit,
               "revision" => revision
             }
           } = get(build_conn(), "/api/v1/groups/#{group_id}") |> json_response(200)

    {outstanding, cash, credit, revision}
  end

  defp group_revision(group_id) do
    assert %{"data" => %{"revision" => revision}} =
             get(build_conn(), "/api/v1/groups/#{group_id}") |> json_response(200)

    revision
  end

  defp ledger, do: get(build_conn(), "/api/v1/ledger?on=2027-01-10") |> json_response(200)

  defp payment_statement(operation_id) do
    get(build_conn(), "/api/v1/payments/#{operation_id}") |> json_response(200)
  end

  defp cash_allocations(group_id) do
    CashAllocation
    |> join(:inner, [a], r in Room, on: r.id == a.room_id)
    |> join(:inner, [a, _r], s in CashSource, on: s.id == a.cash_source_id)
    |> where([_a, r, _s], r.group_id == ^group_id)
    |> order_by([a, _r, _s], asc: a.allocation_order)
    |> select([a, r, s], {r.room_id, s.payment_operation_id, a.amount_cents})
    |> Repo.all()
  end

  defp credit_allocations(group_id) do
    CreditAllocation
    |> join(:inner, [a], r in Room, on: r.id == a.room_id)
    |> join(:inner, [a, _r], l in assoc(a, :credit_lot))
    |> where([_a, r, _l], r.group_id == ^group_id)
    |> order_by([a, _r, _l], asc: a.allocation_order)
    |> select([a, r, l], {r.room_id, l.source_operation_id, a.amount_cents})
    |> Repo.all()
  end
end
