defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  test "moves newest cash and credit allocations in order without changing ledger totals", %{
    conn: conn
  } do
    post_batch(conn, [
      open("seed", "guest", [100]),
      cash("seed", "seed-pay", 100),
      cancel("seed", "seed-credit", "2026-11-26", "hotel_credit"),
      open("source", "guest", [100, 100, 100]),
      cash("source", "pay", 150),
      credit("source", "apply-credit", 100),
      open("destination", "guest", [60, 100])
    ])

    before_transfer = ledger()

    operation = transfer("move", "source", "destination", 125, 3, 1) |> Map.delete("occurred_on")
    [result] = post_batch(build_conn(), [operation])

    assert result == %{
             "operation_id" => "move",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 125,
             "source_outstanding_deposit_cents" => 175,
             "destination_outstanding_deposit_cents" => 35,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert room_funding("source") == [{100, 0}, {25, 0}, {0, 0}]
    assert room_funding("destination") == [{0, 60}, {25, 40}]
    assert ledger() == before_transfer

    assert payment("pay")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 25},
             %{"group_id" => "source", "amount_cents" => 125}
           ]

    assert post_batch(build_conn(), [operation]) == [result]
    assert {group("source")["revision"], group("destination")["revision"]} == {4, 2}

    [conflict] = post_batch(build_conn(), [%{operation | "amount_cents" => 124}])
    assert conflict["code"] == "operation_id_conflict"
  end

  test "resolves groups and revisions before transfer domain validation", %{conn: conn} do
    post_batch(conn, [
      open("source", "guest", [100]),
      cash("source", "pay", 50),
      open("destination", "guest", [100]),
      open("other-guest", "other", [100])
    ])

    operations = [
      transfer("missing-source", "missing", "also-missing", 0),
      transfer("missing-destination", "source", "missing", 0, 1, 99),
      transfer("source-stale", "source", "destination", 0, 1, 99),
      transfer("destination-stale", "source", "destination", 0, 2, 99),
      transfer("same", "source", "source", 1),
      transfer("guest-mismatch", "source", "other-guest", 1),
      transfer("invalid-amount", "source", "destination", 0),
      transfer("not-held", "source", "destination", 51)
    ]

    results = post_batch(build_conn(), operations)

    assert Enum.map(results, & &1["code"]) == [
             "group_not_found",
             "group_not_found",
             "stale_revision",
             "stale_revision",
             "invalid_transfer",
             "invalid_transfer",
             "invalid_amount",
             "transfer_exceeds_held_funding"
           ]

    assert Enum.at(results, 0)["group_id"] == "missing"
    assert Enum.at(results, 1)["group_id"] == "missing"
    assert Enum.at(results, 2)["group_id"] == "source"
    assert Enum.at(results, 3)["group_id"] == "destination"
    assert {group("source")["revision"], group("destination")["revision"]} == {2, 1}

    post_batch(build_conn(), [cash("destination", "destination-pay", 90)])
    [too_full] = post_batch(build_conn(), [transfer("too-full", "source", "destination", 20)])
    assert too_full["code"] == "transfer_exceeds_outstanding"

    post_batch(build_conn(), [
      open("cancelled-source", "guest", [100]),
      cancel("cancelled-source", "cancel-source", "2026-11-26"),
      open("cancelled-destination", "guest", [100]),
      cancel("cancelled-destination", "cancel-destination", "2026-11-26")
    ])

    [source_inactive, destination_inactive] =
      post_batch(build_conn(), [
        transfer("source-inactive", "cancelled-source", "destination", 1),
        transfer("destination-inactive", "source", "cancelled-destination", 1)
      ])

    assert Map.take(source_inactive, ["code", "group_id"]) == %{
             "code" => "group_not_active",
             "group_id" => "cancelled-source"
           }

    assert Map.take(destination_inactive, ["code", "group_id"]) == %{
             "code" => "group_not_active",
             "group_id" => "cancelled-destination"
           }
  end

  test "reductions follow transferred allocations and revise every changed group", %{conn: conn} do
    post_batch(conn, [
      open("source", "guest", [100, 100]),
      cash("source", "pay", 200),
      open("destination", "guest", [100, 100]),
      transfer("move", "source", "destination", 150, 2, 1)
    ])

    assert payment("pay")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 150},
             %{"group_id" => "source", "amount_cents" => 50}
           ]

    [first] = post_batch(build_conn(), [reduce("reduce-1", "pay", 125, 3)])
    assert first["revision"] == 4
    assert first["outstanding_deposit_cents"] == 150
    assert room_funding("source") == [{50, 0}, {0, 0}]
    assert room_funding("destination") == [{25, 0}, {0, 0}]
    assert group("destination")["revision"] == 3

    [second] = post_batch(build_conn(), [reduce("reduce-2", "pay", 75, 4)])
    assert second["revision"] == 5
    assert group("destination")["revision"] == 4
    assert payment("pay")["held_by_group"] == []
    assert payment("pay")["held_cents"] == 0
    assert ledger()["cash_reduced_cents"] == 200
  end

  test "chargebacks remove held cash across groups and retain the original payment result", %{
    conn: conn
  } do
    [_, original_payment, _, _] =
      post_batch(conn, [
        open("source", "guest", [100, 100]),
        cash("source", "pay", 200),
        open("destination", "guest", [100, 100]),
        transfer("move", "source", "destination", 150)
      ])

    [charged_back] = post_batch(build_conn(), [chargeback("chargeback", "pay", 3)])

    assert charged_back["charged_back_cents"] == 200
    assert charged_back["group_id"] == "source"
    assert charged_back["revision"] == 4
    assert group("destination")["revision"] == 3
    assert room_funding("source") == [{0, 0}, {0, 0}]
    assert room_funding("destination") == [{0, 0}, {0, 0}]
    assert payment("pay")["held_by_group"] == []
    assert payment("pay")["charged_back_cents"] == 200
    assert operation("pay") == original_payment
  end

  test "transferred cash settles under the destination cancellation policy", %{conn: conn} do
    post_batch(conn, [
      open("source", "guest", [100], booked_on: "2026-10-03", arrival_on: "2026-12-10"),
      cash("source", "pay", 100),
      open("destination", "guest", [100],
        booked_on: "2027-01-01",
        arrival_on: "2027-03-10"
      ),
      transfer("move", "source", "destination", 100),
      cancel("destination", "cancel-destination", "2027-02-01")
    ])

    statement = payment("pay")
    assert statement["held_by_group"] == []
    assert statement["refunded_cents"] == 100
    assert statement["retained_cents"] == 0
    assert ledger()["cash_refunded_cents"] == 100
  end

  test "transferred credit returns to its original lot without a second bonus", %{conn: conn} do
    post_batch(conn, [
      open("seed", "guest", [100]),
      cash("seed", "seed-pay", 100),
      cancel("seed", "original-lot", "2026-11-26", "hotel_credit"),
      open("source", "guest", [100]),
      credit("source", "spend", 100),
      open("destination", "guest", [100]),
      transfer("move-credit", "source", "destination", 100),
      cancel("destination", "restore", "2026-11-26")
    ])

    credit_view = guest_credit("guest", "2026-11-26")
    assert credit_view["available_cents"] == 110

    assert credit_view["lots"] == [
             %{
               "source_operation_id" => "original-lot",
               "remaining_cents" => 110,
               "expires_on" => "2027-11-26"
             }
           ]

    assert operation("restore")["credit_issued_cents"] == 0
  end

  defp open(group_id, guest_id, deposits, options \\ []) do
    booked_on = Keyword.get(options, :booked_on, "2026-10-03")
    arrival_on = Keyword.get(options, :arrival_on, "2026-12-10")

    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => booked_on,
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => arrival_on |> Date.from_iso8601!() |> Date.add(1) |> Date.to_iso8601(),
      "rate_plan" => "flexible",
      "rooms" =>
        deposits
        |> Enum.with_index(1)
        |> Enum.map(fn {deposit, index} ->
          %{"room_id" => "room-#{index}", "nightly_rate_cents" => deposit * 5}
        end)
    }
  end

  defp cash(group_id, operation_id, amount),
    do: operation(operation_id, "record_cash_payment", group_id, %{"amount_cents" => amount})

  defp credit(group_id, operation_id, amount),
    do:
      operation(operation_id, "apply_hotel_credit", group_id, %{
        "amount_cents" => amount,
        "occurred_on" => "2026-11-26"
      })

  defp cancel(group_id, operation_id, on, method \\ "cash"),
    do:
      operation(operation_id, "cancel_group", group_id, %{
        "occurred_on" => on,
        "refund_method" => method
      })

  defp transfer(
         id,
         source,
         destination,
         amount,
         source_revision \\ nil,
         destination_revision \\ nil
       ) do
    %{
      "operation_id" => id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-11-26",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
    |> maybe_put("expected_revision", source_revision)
    |> maybe_put("destination_expected_revision", destination_revision)
  end

  defp reduce(id, payment_id, amount, revision),
    do: %{
      "operation_id" => id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-11-26",
      "payment_operation_id" => payment_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }

  defp chargeback(id, payment_id, revision),
    do: %{
      "operation_id" => id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-11-26",
      "payment_operation_id" => payment_id,
      "expected_revision" => revision
    }

  defp operation(id, type, group_id, extra),
    do:
      Map.merge(
        %{
          "operation_id" => id,
          "type" => type,
          "occurred_on" => "2026-10-04",
          "group_id" => group_id
        },
        extra
      )

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp post_batch(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp group(id),
    do: build_conn() |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp payment(id),
    do:
      build_conn()
      |> get("/api/v1/payments/#{id}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp operation(id),
    do:
      build_conn()
      |> get("/api/v1/operations/#{id}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp guest_credit(guest_id, on),
    do:
      build_conn()
      |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp ledger,
    do:
      build_conn()
      |> get("/api/v1/ledger?on=2026-11-26")
      |> json_response(200)
      |> Map.fetch!("data")

  defp room_funding(group_id),
    do: Enum.map(group(group_id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})
end
