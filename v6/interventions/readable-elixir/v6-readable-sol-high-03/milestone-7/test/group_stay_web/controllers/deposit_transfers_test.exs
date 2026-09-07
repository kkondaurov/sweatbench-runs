defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  describe "moving held funding" do
    test "draws newest funding first, fills destination rooms in order, and preserves the ledger",
         %{conn: conn} do
      submit(conn, [
        open_group("credit-source", "guest"),
        cash_payment("credit-cash", "credit-source", 500),
        cancel_group("issue-credit", "credit-source", "hotel_credit"),
        open_group("source", "guest"),
        cash_payment("cash", "source", 700),
        apply_credit("credit", "source", 500),
        open_group("destination", "guest")
      ])

      ledger_before = ledger(conn)
      transfer = transfer("move", "source", "destination", 800, 3, 1)

      assert %{"results" => [result]} = submit(conn, [transfer])

      assert result == %{
               "operation_id" => "move",
               "status" => "applied",
               "source_group_id" => "source",
               "destination_group_id" => "destination",
               "amount_cents" => 800,
               "source_outstanding_deposit_cents" => 800,
               "destination_outstanding_deposit_cents" => 400,
               "source_revision" => 4,
               "destination_revision" => 2
             }

      assert room_funding(conn, "source") == [{400, 0}, {0, 0}]
      assert room_funding(conn, "destination") == [{100, 500}, {200, 0}]
      assert ledger(conn) == ledger_before

      assert fetch_payment(conn, "cash")["held_by_group"] == [
               %{"group_id" => "destination", "amount_cents" => 300},
               %{"group_id" => "source", "amount_cents" => 400}
             ]

      assert %{"results" => [replayed]} = submit(conn, [transfer])
      assert replayed == result
      assert room_funding(conn, "destination") == [{100, 500}, {200, 0}]
    end

    test "settles transferred funding under the destination policy and restores original credit",
         %{conn: conn} do
      submit(conn, [
        open_group("credit-source", "guest"),
        cash_payment("credit-cash", "credit-source", 500),
        cancel_group("original-lot", "credit-source", "hotel_credit"),
        open_group("source", "guest"),
        cash_payment("cash", "source", 700),
        apply_credit("credit", "source", 500),
        open_group("destination", "guest"),
        transfer("move", "source", "destination", 800)
      ])

      assert %{"results" => [cancelled]} =
               submit(conn, [cancel_group("destination-cancel", "destination", "hotel_credit")])

      assert cancelled["credit_issued_cents"] == 330
      assert cancelled["refunded_cents"] == 0
      assert cancelled["retained_cents"] == 0

      assert fetch_credit(conn, "guest")["lots"] == [
               %{
                 "source_operation_id" => "destination-cancel",
                 "remaining_cents" => 330,
                 "expires_on" => "2027-10-06"
               },
               %{
                 "source_operation_id" => "original-lot",
                 "remaining_cents" => 550,
                 "expires_on" => "2027-10-06"
               }
             ]

      payment = fetch_payment(conn, "cash")
      assert payment["held_cents"] == 400
      assert payment["converted_to_credit_cents"] == 300
      assert payment["held_by_group"] == [%{"group_id" => "source", "amount_cents" => 400}]
    end

    test "resolves groups and both revision guards before transfer validation", %{conn: conn} do
      submit(conn, [
        open_group("source", "guest"),
        cash_payment("cash", "source", 600),
        open_group("destination", "guest"),
        cash_payment("destination-cash", "destination", 1_000),
        open_group("other-guest", "other")
      ])

      operations = [
        transfer("missing-source", "missing", "destination", 1),
        transfer("missing-destination", "source", "missing", 1),
        transfer("stale-source", "source", "destination", 1, 1, 0),
        transfer("stale-destination", "source", "destination", 1, 2, 1),
        transfer("same", "source", "source", 1, 2, 2),
        transfer("different-guests", "source", "other-guest", 1),
        transfer("invalid-amount", "source", "destination", 0),
        transfer("too-much-held", "source", "destination", 601),
        transfer("too-much-outstanding", "source", "destination", 201)
      ]

      assert %{"results" => results} = submit(conn, operations)

      assert Enum.at(results, 0) == rejected_group("missing-source", "group_not_found", "missing")

      assert Enum.at(results, 1) ==
               rejected_group("missing-destination", "group_not_found", "missing")

      assert Enum.at(results, 2) == stale("stale-source", "source", 1, 2)
      assert Enum.at(results, 3) == stale("stale-destination", "destination", 1, 2)

      assert Enum.map(Enum.drop(results, 4), & &1["code"]) == [
               "invalid_transfer",
               "invalid_transfer",
               "invalid_amount",
               "transfer_exceeds_held_funding",
               "transfer_exceeds_outstanding"
             ]

      assert fetch_group(conn, "source")["revision"] == 2
      assert fetch_group(conn, "destination")["revision"] == 2
    end

    test "identifies whichever group is inactive", %{conn: conn} do
      submit(conn, [
        open_group("source", "guest"),
        cash_payment("cash", "source", 100),
        open_group("destination", "guest"),
        cancel_group("cancel-destination", "destination", nil),
        open_group("active", "guest")
      ])

      assert %{"results" => [inactive_destination]} =
               submit(conn, [transfer("to-cancelled", "source", "destination", 1)])

      assert inactive_destination ==
               rejected_group("to-cancelled", "group_not_active", "destination")

      submit(conn, [cancel_group("cancel-source", "source", nil)])

      assert %{"results" => [inactive_source]} =
               submit(conn, [transfer("from-cancelled", "source", "active", 1)])

      assert inactive_source == rejected_group("from-cancelled", "group_not_active", "source")
    end
  end

  describe "corrections after transfers" do
    test "reductions and chargebacks follow allocations and revise every changed group", %{
      conn: conn
    } do
      %{"results" => setup_results} =
        submit(conn, [
          open_group("source", "guest"),
          cash_payment("cash", "source", 900),
          open_group("destination-a", "guest"),
          open_group("destination-b", "guest"),
          transfer("move-a", "source", "destination-a", 300),
          transfer("move-b", "source", "destination-b", 200)
        ])

      assert Enum.all?(setup_results, &(&1["status"] == "applied")), inspect(setup_results)

      reduction = %{
        "operation_id" => "reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-07",
        "payment_operation_id" => "cash",
        "amount_cents" => 350,
        "expected_revision" => 4
      }

      assert %{"results" => [reduced]} = submit(conn, [reduction])
      assert reduced["revision"] == 5
      assert reduced["outstanding_deposit_cents"] == 800

      assert fetch_group(conn, "destination-a")["revision"] == 3
      assert fetch_group(conn, "destination-b")["revision"] == 3

      assert fetch_payment(conn, "cash")["held_by_group"] == [
               %{"group_id" => "destination-a", "amount_cents" => 150},
               %{"group_id" => "source", "amount_cents" => 400}
             ]

      chargeback = %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-08",
        "payment_operation_id" => "cash",
        "expected_revision" => 5
      }

      assert %{"results" => [charged_back]} = submit(conn, [chargeback])
      assert charged_back["charged_back_cents"] == 550
      assert charged_back["revision"] == 6

      assert fetch_group(conn, "destination-a")["revision"] == 4
      assert fetch_group(conn, "destination-b")["revision"] == 3
      assert fetch_payment(conn, "cash")["held_by_group"] == []
    end
  end

  defp open_group(group_id, guest_id) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 1_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 1_000}
      ]
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp apply_credit(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_group(operation_id, group_id, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id
    }
    |> then(fn operation ->
      if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation
    end)
  end

  defp transfer(
         operation_id,
         source_id,
         destination_id,
         amount_cents,
         source_revision \\ nil,
         destination_revision \\ nil
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-06",
      "source_group_id" => source_id,
      "destination_group_id" => destination_id,
      "amount_cents" => amount_cents
    }
    |> maybe_put("expected_revision", source_revision)
    |> maybe_put("destination_expected_revision", destination_revision)
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp fetch_group(conn, group_id) do
    %{"data" => group} = conn |> get("/api/v1/groups/#{group_id}") |> json_response(200)
    group
  end

  defp fetch_payment(conn, operation_id) do
    %{"data" => payment} =
      conn |> get("/api/v1/payments/#{operation_id}") |> json_response(200)

    payment
  end

  defp fetch_credit(conn, guest_id) do
    %{"data" => credit} =
      conn
      |> get("/api/v1/guests/#{guest_id}/credit?on=2026-10-07")
      |> json_response(200)

    credit
  end

  defp ledger(conn) do
    %{"data" => totals} = conn |> get("/api/v1/ledger?on=2026-10-07") |> json_response(200)
    totals
  end

  defp room_funding(conn, group_id) do
    conn
    |> fetch_group(group_id)
    |> Map.fetch!("rooms")
    |> Enum.map(&{&1["cash_paid_cents"], &1["credit_paid_cents"]})
  end

  defp rejected_group(operation_id, code, group_id) do
    %{
      "operation_id" => operation_id,
      "status" => "rejected",
      "code" => code,
      "group_id" => group_id
    }
  end

  defp stale(operation_id, group_id, expected, actual) do
    %{
      "operation_id" => operation_id,
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => group_id,
      "expected_revision" => expected,
      "actual_revision" => actual
    }
  end

  defp maybe_put(operation, _field, nil), do: operation
  defp maybe_put(operation, field, value), do: Map.put(operation, field, value)
end
