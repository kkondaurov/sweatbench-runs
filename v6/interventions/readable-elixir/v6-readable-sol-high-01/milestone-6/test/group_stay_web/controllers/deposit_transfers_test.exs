defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  describe "moving held funding" do
    test "draws cash and credit in reverse allocation order and preserves provenance", %{
      conn: conn
    } do
      issue_credit(conn, "guest", 2_000)
      submit(conn, open_group("source", two_rooms(), guest_id: "guest"))
      submit(conn, open_group("destination", two_rooms(5_000), guest_id: "guest"))

      submit(conn, cash_payment("old-cash", "source", 1_500))
      submit(conn, credit_payment("applied-credit", "source", 1_000))
      submit(conn, cash_payment("new-cash", "source", 500))

      ledger_before = ledger(conn)

      assert submit(conn, transfer("move", "source", "destination", 1_200)) == %{
               "operation_id" => "move",
               "status" => "applied",
               "source_group_id" => "source",
               "destination_group_id" => "destination",
               "amount_cents" => 1_200,
               "source_outstanding_deposit_cents" => 2_200,
               "destination_outstanding_deposit_cents" => 800,
               "source_revision" => 5,
               "destination_revision" => 2
             }

      source = group(conn, "source")
      destination = group(conn, "destination")

      assert {source["cash_paid_cents"], source["credit_paid_cents"]} == {1_500, 300}
      assert {destination["cash_paid_cents"], destination["credit_paid_cents"]} == {500, 700}

      assert Enum.map(destination["rooms"], fn room ->
               {room["cash_paid_cents"], room["credit_paid_cents"]}
             end) == [{500, 500}, {0, 200}]

      assert payment(conn, "new-cash")["held_by_group"] == [
               %{"group_id" => "destination", "amount_cents" => 500}
             ]

      refute Map.has_key?(payment(conn, "old-cash"), "held_by_group")
      assert ledger(conn) == ledger_before

      assert submit(conn, transfer("move", "source", "destination", 1_200))["source_revision"] ==
               5
    end

    test "supports same-batch visibility and guards both revisions before validation", %{
      conn: conn
    } do
      submit(conn, open_group("source", two_rooms(), guest_id: "guest"))
      submit(conn, open_group("destination", two_rooms(), guest_id: "guest"))
      submit(conn, cash_payment("cash", "source", 1_000))

      stale_source =
        transfer("stale-source", "source", "destination", -1,
          expected_revision: 1,
          destination_expected_revision: 1
        )

      assert submit(conn, stale_source) == %{
               "operation_id" => "stale-source",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "source",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      stale_destination =
        transfer("stale-destination", "source", "destination", -1,
          expected_revision: 2,
          destination_expected_revision: 99
        )

      assert submit(conn, stale_destination) == %{
               "operation_id" => "stale-destination",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "destination",
               "expected_revision" => 99,
               "actual_revision" => 1
             }

      assert submit(conn, transfer("bad-amount", "source", "destination", 0))["code"] ==
               "invalid_amount"

      batch = [
        cash_payment("same-batch-cash", "source", 500),
        transfer("same-batch-transfer", "source", "destination", 500,
          expected_revision: 3,
          destination_expected_revision: 1
        )
      ]

      assert [_payment, moved] = submit_batch(conn, batch)
      assert moved["status"] == "applied"
      assert moved["source_revision"] == 4
      assert moved["destination_revision"] == 2
    end

    test "uses stable group and transfer validation errors without changing state", %{conn: conn} do
      submit(conn, open_group("source", two_rooms(), guest_id: "guest"))
      submit(conn, open_group("destination", two_rooms(), guest_id: "other"))
      submit(conn, cash_payment("cash", "source", 1_000))

      assert submit(conn, transfer("missing-source", "missing", "also-missing", 1)) == %{
               "operation_id" => "missing-source",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "missing"
             }

      assert submit(conn, transfer("missing-destination", "source", "missing", 1))["group_id"] ==
               "missing"

      assert submit(conn, transfer("different-guests", "source", "destination", 1))["code"] ==
               "invalid_transfer"

      assert submit(conn, transfer("same-group", "source", "source", 1))["code"] ==
               "invalid_transfer"

      submit(conn, open_group("large", two_rooms(), guest_id: "guest"))

      assert submit(conn, transfer("too-much-source", "source", "large", 1_001))["code"] ==
               "transfer_exceeds_held_funding"

      submit(conn, open_group("small", [room("small", 1_000)], guest_id: "guest"))

      assert submit(conn, transfer("too-much-destination", "source", "small", 201))["code"] ==
               "transfer_exceeds_outstanding"

      assert group(conn, "source")["revision"] == 2
      assert group(conn, "small")["revision"] == 1

      submit(conn, cancel_group("cancel-large", "large", "2026-11-01"))

      assert submit(conn, transfer("inactive-destination", "source", "large", 1)) == %{
               "operation_id" => "inactive-destination",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "large"
             }
    end
  end

  describe "later settlement and provider corrections" do
    test "settles transferred cash under the destination policy and charges it back there", %{
      conn: conn
    } do
      submit(conn, open_group("source", [room("source-room", 10_000)], guest_id: "guest"))

      submit(
        conn,
        open_group("destination", [room("destination-room", 1_000)],
          guest_id: "guest",
          rate_plan: "advance_purchase"
        )
      )

      submit(conn, cash_payment("cash", "source", 2_000))
      submit(conn, transfer("move", "source", "destination", 1_000))

      assert payment(conn, "cash")["held_by_group"] == [
               %{"group_id" => "destination", "amount_cents" => 1_000},
               %{"group_id" => "source", "amount_cents" => 1_000}
             ]

      submit(conn, cancel_group("cancel-destination", "destination", "2026-10-03"))

      assert ledger(conn)["cash_retained_cents"] == 1_000

      chargeback = charge_back("chargeback", "cash", expected_revision: 3)

      assert submit(conn, chargeback) == %{
               "operation_id" => "chargeback",
               "status" => "applied",
               "payment_operation_id" => "cash",
               "group_id" => "source",
               "charged_back_cents" => 2_000,
               "outstanding_deposit_cents" => 2_000,
               "revision" => 4
             }

      assert group(conn, "destination")["revision"] == 4
      assert ledger(conn)["cash_retained_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 2_000
      assert payment(conn, "cash")["held_by_group"] == []
    end

    test "reduces a transferred payment across groups in reverse allocation order", %{conn: conn} do
      submit(conn, open_group("source", two_rooms(), guest_id: "guest"))
      submit(conn, open_group("destination", two_rooms(), guest_id: "guest"))
      submit(conn, cash_payment("cash", "source", 2_000))
      submit(conn, transfer("move", "source", "destination", 1_000))

      assert submit(conn, reduce_payment("reduce", "cash", 1_500, expected_revision: 3)) == %{
               "operation_id" => "reduce",
               "status" => "applied",
               "payment_operation_id" => "cash",
               "group_id" => "source",
               "amount_cents" => 1_500,
               "outstanding_deposit_cents" => 3_500,
               "revision" => 4
             }

      assert group(conn, "destination")["revision"] == 3
      assert group(conn, "destination")["cash_paid_cents"] == 0

      assert payment(conn, "cash")["held_by_group"] == [
               %{"group_id" => "source", "amount_cents" => 500}
             ]
    end

    test "restores transferred hotel credit to its original lot", %{conn: conn} do
      issue_credit(conn, "guest", 1_000)
      submit(conn, open_group("source", two_rooms(), guest_id: "guest"))
      submit(conn, open_group("destination", two_rooms(), guest_id: "guest"))
      submit(conn, credit_payment("spend", "source", 1_000))
      submit(conn, transfer("move", "source", "destination", 600))

      assert credit(conn, "guest", "2026-12-01")["available_cents"] == 100

      submit(conn, cancel_group("cancel-destination", "destination", "2026-12-01"))

      credit = credit(conn, "guest", "2026-12-01")
      assert credit["available_cents"] == 700
      assert [%{"source_operation_id" => "credit-origin"}] = credit["lots"]
      assert group(conn, "source")["credit_paid_cents"] == 400
      assert ledger(conn)["credit_liability_cents"] == 1_100
    end
  end

  defp submit(conn, operation), do: submit_batch(conn, [operation]) |> hd()

  defp submit_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp payment(conn, operation_id) do
    conn
    |> get("/api/v1/payments/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp credit(conn, guest_id, on) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger?on=2026-12-01") |> json_response(200) |> Map.fetch!("data")
  end

  defp issue_credit(conn, guest_id, cash_cents) do
    submit(
      conn,
      open_group("credit-donor", [room("donor-room", cash_cents * 5)], guest_id: guest_id)
    )

    submit(conn, cash_payment("donor-cash", "credit-donor", cash_cents))

    submit(
      conn,
      cancel_group("credit-origin", "credit-donor", "2026-11-01", refund_method: "hotel_credit")
    )
  end

  defp open_group(group_id, rooms, options) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => Keyword.get(options, :guest_id, "guest-#{group_id}"),
      "property_id" => "hotel",
      "arrival_on" => "2027-03-01",
      "departure_on" => "2027-03-02",
      "rate_plan" => Keyword.get(options, :rate_plan, "flexible"),
      "rooms" => rooms
    }
  end

  defp two_rooms(rate \\ 10_000), do: [room("room-1", rate), room("room-2", rate)]
  defp room(id, rate), do: %{"room_id" => id, "nightly_rate_cents" => rate}

  defp cash_payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp credit_payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-11-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(operation_id, source, destination, amount, options \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-11-03",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
    |> maybe_put("expected_revision", options[:expected_revision])
    |> maybe_put("destination_expected_revision", options[:destination_expected_revision])
  end

  defp cancel_group(operation_id, group_id, occurred_on, options \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
    |> maybe_put("refund_method", options[:refund_method])
  end

  defp reduce_payment(operation_id, payment_operation_id, amount, options) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-11-04",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount
    }
    |> maybe_put("expected_revision", options[:expected_revision])
  end

  defp charge_back(operation_id, payment_operation_id, options) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-11-04",
      "payment_operation_id" => payment_operation_id
    }
    |> maybe_put("expected_revision", options[:expected_revision])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
