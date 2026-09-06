defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  test "moves newest funding first and follows cash across groups for corrections", %{conn: conn} do
    submit(conn, [
      open("source", "guest", [room("s-a", 500), room("s-b", 500)]),
      open("destination", "guest", [room("d-a", 500), room("d-b", 500)]),
      cash("pay-1", "source", 120),
      cash("pay-2", "source", 60)
    ])

    refute Map.has_key?(payment(conn, "pay-1"), "held_by_group")

    transfer =
      transfer("move", "source", "destination", 80, 3, 1)
      |> then(&submit(conn, [&1]))
      |> only_result()

    assert transfer == %{
             "operation_id" => "move",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 80,
             "source_outstanding_deposit_cents" => 100,
             "destination_outstanding_deposit_cents" => 120,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert Enum.map(group(conn, "source")["rooms"], & &1["cash_paid_cents"]) == [100, 0]
    assert Enum.map(group(conn, "destination")["rooms"], & &1["cash_paid_cents"]) == [80, 0]

    assert payment(conn, "pay-1")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 20},
             %{"group_id" => "source", "amount_cents" => 100}
           ]

    assert payment(conn, "pay-2")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 60}
           ]

    reduced = submit(conn, [reduce("reduce", "pay-1", 30, 4)]) |> only_result()
    assert reduced["revision"] == 5
    assert reduced["outstanding_deposit_cents"] == 110
    assert group(conn, "destination")["revision"] == 3
    assert group(conn, "destination")["cash_paid_cents"] == 60
    assert group(conn, "source")["cash_paid_cents"] == 90

    charged = submit(conn, [chargeback("chargeback", "pay-2", 5)]) |> only_result()
    assert charged["revision"] == 6
    assert charged["outstanding_deposit_cents"] == 110
    assert group(conn, "destination")["revision"] == 4
    assert group(conn, "destination")["cash_paid_cents"] == 0
    assert payment(conn, "pay-2")["held_by_group"] == []

    assert Map.take(ledger(conn), [
             "cash_held_cents",
             "cash_reduced_cents",
             "cash_charged_back_cents"
           ]) == %{
             "cash_held_cents" => 90,
             "cash_reduced_cents" => 30,
             "cash_charged_back_cents" => 60
           }
  end

  test "preserves cash and credit provenance and settles under the destination policy", %{
    conn: conn
  } do
    submit(conn, [
      open("credit-maker", "guest", [room("maker", 500)]),
      cash("seed-cash", "credit-maker", 100),
      cancel("issue-credit", "credit-maker", "2026-10-03", "hotel_credit"),
      open("source", "guest", [room("source-room", 1_000)]),
      open("destination", "guest", [room("destination-room", 1_000)], "advance_purchase"),
      cash("source-cash", "source", 50),
      credit("source-credit", "source", 110)
    ])

    before = ledger(conn)

    result =
      submit(conn, [transfer("mixed", "source", "destination", 120, 3, 1)]) |> only_result()

    assert result["status"] == "applied"
    assert ledger(conn) == before
    assert group(conn, "source")["cash_paid_cents"] == 40
    assert group(conn, "source")["credit_paid_cents"] == 0
    assert group(conn, "destination")["cash_paid_cents"] == 10
    assert group(conn, "destination")["credit_paid_cents"] == 110

    cancelled =
      submit(conn, [cancel("cancel-destination", "destination", "2026-10-04")]) |> only_result()

    assert cancelled["retained_cents"] == 10
    assert cancelled["refunded_cents"] == 0
    assert cancelled["credit_issued_cents"] == 0
    assert credit_view(conn)["available_cents"] == 0

    source_revision = group(conn, "source")["revision"]
    destination_revision = group(conn, "destination")["revision"]

    charged =
      submit(conn, [chargeback("charge-source-cash", "source-cash", source_revision)])
      |> only_result()

    assert charged["charged_back_cents"] == 50
    assert group(conn, "source")["revision"] == source_revision + 1
    assert group(conn, "destination")["revision"] == destination_revision + 1
    assert ledger(conn)["cash_retained_cents"] == 0
  end

  test "checks existence and both revisions before transfer domain validation", %{conn: conn} do
    submit(conn, [
      open("source", "guest", [room("source-room", 500)]),
      open("destination", "other-guest", [room("destination-room", 500)]),
      cash("payment", "source", 50)
    ])

    missing_source = transfer("missing-source", "absent", "destination", 0)
    missing_destination = transfer("missing-destination", "source", "absent", 0)
    stale_source = transfer("stale-source", "source", "destination", 0, 1, 1)
    stale_destination = transfer("stale-destination", "source", "destination", 0, 2, 9)

    assert %{"code" => "group_not_found", "group_id" => "absent"} =
             submit(conn, [missing_source]) |> only_result()

    assert %{"code" => "group_not_found", "group_id" => "absent"} =
             submit(conn, [missing_destination]) |> only_result()

    assert %{
             "code" => "stale_revision",
             "group_id" => "source",
             "expected_revision" => 1,
             "actual_revision" => 2
           } = submit(conn, [stale_source]) |> only_result()

    assert %{
             "code" => "stale_revision",
             "group_id" => "destination",
             "expected_revision" => 9,
             "actual_revision" => 1
           } = submit(conn, [stale_destination]) |> only_result()

    assert submit(conn, [transfer("different-guests", "source", "destination", 10)])
           |> only_result()
           |> Map.fetch!("code") == "invalid_transfer"

    assert group(conn, "source")["revision"] == 2
    assert group(conn, "destination")["revision"] == 1
  end

  test "validates active groups and both transfer capacities atomically", %{conn: conn} do
    submit(conn, [
      open("source", "guest", [room("source-room", 500)]),
      open("destination", "guest", [room("destination-room", 500)]),
      cash("payment", "source", 60),
      cash("destination-payment", "destination", 90)
    ])

    assert transfer_code(conn, transfer("bad-amount", "source", "destination", 0)) ==
             "invalid_amount"

    assert transfer_code(conn, transfer("too-much-held", "source", "destination", 61)) ==
             "transfer_exceeds_held_funding"

    assert transfer_code(conn, transfer("too-much-outstanding", "source", "destination", 11)) ==
             "transfer_exceeds_outstanding"

    submit(conn, [cancel("cancel-destination", "destination", "2026-10-03")])

    inactive = submit(conn, [transfer("inactive", "source", "destination", 10)]) |> only_result()
    assert inactive["code"] == "group_not_active"
    assert inactive["group_id"] == "destination"
    assert group(conn, "source")["cash_paid_cents"] == 60
  end

  test "is visible within a batch and durable retries do not move funding twice", %{conn: conn} do
    operation = transfer("move-once", "source", "destination", 50, 2, 1)

    response =
      submit(conn, [
        open("source", "guest", [room("source-room", 500)]),
        open("destination", "guest", [room("destination-room", 500)]),
        cash("payment", "source", 50),
        operation
      ])

    original = List.last(response["results"])
    assert original["status"] == "applied"
    assert submit(conn, [operation]) |> only_result() == original
    assert group(conn, "source")["cash_paid_cents"] == 0
    assert group(conn, "destination")["cash_paid_cents"] == 50
    assert group(conn, "source")["revision"] == 3
    assert group(conn, "destination")["revision"] == 2
  end

  defp submit(conn, operations),
    do:
      conn |> post("/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)

  defp only_result(%{"results" => [result]}), do: result

  defp transfer_code(conn, operation),
    do: submit(conn, [operation]) |> only_result() |> Map.fetch!("code")

  defp group(conn, id),
    do: conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp payment(conn, id),
    do: conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn),
    do: conn |> get("/api/v1/ledger?on=2026-10-05") |> json_response(200) |> Map.fetch!("data")

  defp credit_view(conn),
    do:
      conn
      |> get("/api/v1/guests/guest/credit?on=2026-10-05")
      |> json_response(200)
      |> Map.fetch!("data")

  defp room(id, rate), do: %{"room_id" => id, "nightly_rate_cents" => rate}

  defp open(id, guest, rooms, rate_plan \\ "flexible"),
    do: %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => id,
      "guest_id" => guest,
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => rate_plan,
      "rooms" => rooms
    }

  defp cash(id, group_id, amount),
    do: %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }

  defp credit(id, group_id, amount),
    do: %{
      "operation_id" => id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "amount_cents" => amount
    }

  defp cancel(id, group_id, date, method \\ nil) do
    operation = %{
      "operation_id" => id,
      "type" => "cancel_group",
      "occurred_on" => date,
      "group_id" => group_id
    }

    if method, do: Map.put(operation, "refund_method", method), else: operation
  end

  defp transfer(
         id,
         source,
         destination,
         amount,
         source_revision \\ nil,
         destination_revision \\ nil
       ) do
    operation = %{
      "operation_id" => id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-03",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }

    operation =
      if source_revision,
        do: Map.put(operation, "expected_revision", source_revision),
        else: operation

    if destination_revision,
      do: Map.put(operation, "destination_expected_revision", destination_revision),
      else: operation
  end

  defp reduce(id, payment_id, amount, revision),
    do: %{
      "operation_id" => id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-04",
      "payment_operation_id" => payment_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }

  defp chargeback(id, payment_id, revision),
    do: %{
      "operation_id" => id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-05",
      "payment_operation_id" => payment_id,
      "expected_revision" => revision
    }
end
