defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  describe "transfer_deposit" do
    test "moves the newest funding first, preserves payment identity, and updates both revisions",
         %{conn: conn} do
      transfer = transfer("move", "source", "destination", 1_500, 3, 1)

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open("source", "guest", [1_000, 1_000]),
            open("destination", "guest", [1_000, 1_000]),
            cash("pay-1", "source", 1_000, 1),
            cash("pay-2", "source", 1_000, 2),
            transfer,
            transfer
          ]
        })

      assert %{"results" => [_, _, _, _, moved, replay]} = json_response(conn, 200)
      assert moved == replay

      assert moved == %{
               "operation_id" => "move",
               "status" => "applied",
               "source_group_id" => "source",
               "destination_group_id" => "destination",
               "amount_cents" => 1_500,
               "source_outstanding_deposit_cents" => 1_500,
               "destination_outstanding_deposit_cents" => 500,
               "source_revision" => 4,
               "destination_revision" => 2
             }

      assert %{"rooms" => [first, second]} = get_data(conn, "/api/v1/groups/destination")
      assert first["cash_paid_cents"] == 1_000
      assert second["cash_paid_cents"] == 500

      assert get_data(conn, "/api/v1/payments/pay-1")["held_by_group"] == [
               %{"group_id" => "destination", "amount_cents" => 500},
               %{"group_id" => "source", "amount_cents" => 500}
             ]

      assert get_data(conn, "/api/v1/payments/pay-2")["held_by_group"] == [
               %{"group_id" => "destination", "amount_cents" => 1_000}
             ]

      assert get_data(conn, "/api/v1/ledger")["cash_held_cents"] == 2_000

      conn =
        post(recycle(conn), ~p"/api/v1/partner-batches", %{
          operations: [reduce("reduce-pay-2", "pay-2", 1_000, 4)]
        })

      assert %{"results" => [reduced]} = json_response(conn, 200)
      assert reduced["group_id"] == "source"
      assert reduced["revision"] == 5
      assert reduced["outstanding_deposit_cents"] == 1_500
      assert get_data(conn, "/api/v1/groups/destination")["revision"] == 3
      assert get_data(conn, "/api/v1/groups/destination")["outstanding_deposit_cents"] == 1_500
      assert get_data(conn, "/api/v1/payments/pay-2")["held_by_group"] == []
    end

    test "moves credit without changing its lot, expiry, or ledger liability", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open("issuer", "guest", [1_000]),
            cash("cash", "issuer", 1_000, 1),
            cancel_to_credit("issue", "issuer", 2),
            open("source", "guest", [1_000]),
            open("destination", "guest", [1_000]),
            apply_credit("apply", "source", 1_000, 1),
            transfer("move-credit", "source", "destination", 1_000, 2, 1),
            cancel("restore", "destination", 2)
          ]
        })

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      credit = get_data(conn, "/api/v1/guests/guest/credit?on=2026-10-08")
      assert credit["available_cents"] == 1_100

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "issue",
                 "remaining_cents" => 1_100,
                 "expires_on" => "2027-10-04"
               }
             ]

      ledger = get_data(conn, "/api/v1/ledger?on=2026-10-08")
      assert ledger["cash_converted_to_credit_cents"] == 1_000
      assert ledger["credit_liability_cents"] == 1_100
    end

    test "draws across funding kinds strictly in reverse allocation order", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open("issuer", "guest", [500]),
            cash("issuer-cash", "issuer", 500, 1),
            cancel_to_credit("issue", "issuer", 2),
            open("source", "guest", [1_000]),
            open("destination", "guest", [500]),
            cash("source-cash", "source", 500, 1),
            apply_credit("source-credit", "source", 500, 2),
            transfer("move-newest", "source", "destination", 500, 3, 1)
          ]
        })

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      source = get_data(conn, "/api/v1/groups/source")
      assert source["cash_paid_cents"] == 500
      assert source["credit_paid_cents"] == 0

      destination = get_data(conn, "/api/v1/groups/destination")
      assert destination["cash_paid_cents"] == 0
      assert destination["credit_paid_cents"] == 500

      refute Map.has_key?(get_data(conn, "/api/v1/payments/source-cash"), "held_by_group")
    end

    test "chargeback reverses transferred cash where the destination settled it", %{conn: conn} do
      chargeback = %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-09",
        "payment_operation_id" => "pay",
        "expected_revision" => 3
      }

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open("source", "guest", [1_000]),
            open("destination", "guest", [1_000]),
            cash("pay", "source", 1_000, 1),
            transfer("move", "source", "destination", 1_000, 2, 1),
            cancel("refund", "destination", 2),
            chargeback
          ]
        })

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 5)["revision"] == 4
      assert get_data(conn, "/api/v1/groups/destination")["revision"] == 4

      ledger = get_data(conn, "/api/v1/ledger")
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 1_000

      payment = get_data(conn, "/api/v1/payments/pay")
      assert payment["refunded_cents"] == 0
      assert payment["charged_back_cents"] == 1_000
      assert payment["held_by_group"] == []
    end

    test "validates existence and revisions in order before transfer rules", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open("source", "guest", [1_000]),
            open("destination", "other-guest", [1_000]),
            transfer("missing-source", "missing", "also-missing", 1, nil, nil),
            transfer("missing-destination", "source", "missing", 1, nil, nil),
            transfer("stale-source", "source", "destination", 0, 99, 99),
            transfer("stale-destination", "source", "destination", 0, 1, 99),
            transfer("different-guests", "source", "destination", 1, 1, 1),
            transfer("same-group", "source", "source", 1, 1, 1)
          ]
        })

      assert %{
               "results" => [
                 _,
                 _,
                 missing_source,
                 missing_destination,
                 stale_source,
                 stale_destination,
                 different_guests,
                 same_group
               ]
             } =
               json_response(conn, 200)

      assert rejection_details(missing_source) == {"group_not_found", "missing"}
      assert rejection_details(missing_destination) == {"group_not_found", "missing"}
      assert stale_source["code"] == "stale_revision"
      assert stale_source["group_id"] == "source"
      assert stale_destination["code"] == "stale_revision"
      assert stale_destination["group_id"] == "destination"
      assert different_guests["code"] == "invalid_transfer"
      assert same_group["code"] == "invalid_transfer"
      assert get_data(conn, "/api/v1/groups/source")["revision"] == 1
      assert get_data(conn, "/api/v1/groups/destination")["revision"] == 1
    end

    test "reports transfer limits and identifies the inactive group", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open("source", "guest", [1_000]),
            open("destination", "guest", [1_000]),
            cash("pay", "source", 500, 1),
            transfer("invalid-amount", "source", "destination", 0, 2, 1),
            transfer("too-much-held", "source", "destination", 501, 2, 1),
            cash("fill-destination", "destination", 800, 1),
            transfer("too-much-destination", "source", "destination", 201, 2, 2),
            cancel("cancel-destination", "destination", 2),
            transfer("inactive", "source", "destination", 1, 2, 3)
          ]
        })

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 3)["code"] == "invalid_amount"
      assert Enum.at(results, 4)["code"] == "transfer_exceeds_held_funding"
      assert Enum.at(results, 6)["code"] == "transfer_exceeds_outstanding"
      assert rejection_details(Enum.at(results, 8)) == {"group_not_active", "destination"}
    end
  end

  defp open(group_id, guest_id, deposits) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2027-03-01",
      "departure_on" => "2027-03-02",
      "rate_plan" => "flexible",
      "rooms" =>
        deposits
        |> Enum.with_index(1)
        |> Enum.map(fn {deposit, position} ->
          %{"room_id" => "room-#{position}", "nightly_rate_cents" => deposit * 5}
        end)
    }
  end

  defp cash(operation_id, group_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp apply_credit(operation_id, group_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp transfer(operation_id, source, destination, amount, source_revision, destination_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-06",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
    |> maybe_put("expected_revision", source_revision)
    |> maybe_put("destination_expected_revision", destination_revision)
  end

  defp reduce(operation_id, payment_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-07",
      "payment_operation_id" => payment_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp cancel_to_credit(operation_id, group_id, revision) do
    cancel(operation_id, group_id, revision)
    |> Map.put("occurred_on", "2026-10-04")
    |> Map.put("refund_method", "hotel_credit")
  end

  defp cancel(operation_id, group_id, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2026-10-08",
      "group_id" => group_id,
      "expected_revision" => revision
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp rejection_details(result), do: {result["code"], result["group_id"]}

  defp get_data(conn, path) do
    get(recycle(conn), path) |> json_response(200) |> Map.fetch!("data")
  end
end
