defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  test "moves mixed funding in reverse allocation order and preserves statements and totals" do
    issue_credit("credit-source", "issue-credit", 1_000)

    assert [_, _, _, _] =
             submit([
               open_operation("open-source", "source", 2),
               open_operation("open-destination", "destination", 2),
               cash_operation("pay", "source", 1_500, 1),
               credit_operation("apply", "source", 1_000, 2)
             ])

    ledger_before = ledger()

    transfer = transfer_operation("transfer", "source", "destination", 1_200, 3, 1)
    assert [result] = submit([transfer])

    assert result == %{
             "operation_id" => "transfer",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 1_200,
             "source_outstanding_deposit_cents" => 2_700,
             "destination_outstanding_deposit_cents" => 2_800,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert room_balances("source") == [
             {"room-1", 1_300, 0},
             {"room-2", 0, 0}
           ]

    assert room_balances("destination") == [
             {"room-1", 200, 1_000},
             {"room-2", 0, 0}
           ]

    assert payment("pay")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 200},
             %{"group_id" => "source", "amount_cents" => 1_300}
           ]

    assert ledger() == ledger_before
    assert submit([transfer]) == [result]
    assert get_group("source")["revision"] == 4
    assert get_group("destination")["revision"] == 2
  end

  test "uses two-group existence and revision precedence before transfer validation" do
    assert [_, _, _, _] =
             submit([
               open_operation("open-source", "source", 2),
               open_operation("open-destination", "destination", 1),
               open_operation("open-other", "other", 1, "other-guest"),
               cash_operation("pay", "source", 3_000, 1)
             ])

    assert [missing_source, missing_destination, stale_source, stale_destination] =
             submit([
               transfer_operation("missing-source", "missing", "also-missing", -1),
               transfer_operation("missing-destination", "source", "missing", -1),
               transfer_operation("stale-source", "source", "destination", -1, 1, 99),
               transfer_operation("stale-destination", "source", "destination", -1, 2, 99)
             ])

    assert missing_source["code"] == "group_not_found"
    assert missing_source["group_id"] == "missing"
    assert missing_destination["code"] == "group_not_found"
    assert missing_destination["group_id"] == "missing"

    assert stale_source
           |> Map.take(["code", "group_id", "expected_revision", "actual_revision"]) == %{
             "code" => "stale_revision",
             "group_id" => "source",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert stale_destination
           |> Map.take(["code", "group_id", "expected_revision", "actual_revision"]) == %{
             "code" => "stale_revision",
             "group_id" => "destination",
             "expected_revision" => 99,
             "actual_revision" => 1
           }

    assert [same, different_guest, invalid_amount, too_much_funding, too_much_outstanding] =
             submit([
               transfer_operation("same", "source", "source", 1, 2, 2),
               transfer_operation("different", "source", "other", 1, 2, 1),
               transfer_operation("invalid-amount", "source", "destination", 0, 2, 1),
               transfer_operation("too-much-funding", "source", "destination", 3_001, 2, 1),
               transfer_operation("too-much-outstanding", "source", "destination", 2_500, 2, 1)
             ])

    assert same["code"] == "invalid_transfer"
    assert different_guest["code"] == "invalid_transfer"
    assert invalid_amount["code"] == "invalid_amount"
    assert too_much_funding["code"] == "transfer_exceeds_held_funding"
    assert too_much_outstanding["code"] == "transfer_exceeds_outstanding"

    assert [cancelled] = submit([cancel_operation("cancel-destination", "destination", 1)])
    assert cancelled["revision"] == 2

    assert [inactive] =
             submit([
               transfer_operation("inactive", "source", "destination", 1, 2, 2)
             ])

    assert inactive["code"] == "group_not_active"
    assert inactive["group_id"] == "destination"
    assert get_group("source")["revision"] == 2
  end

  test "reductions and chargebacks follow transferred cash and revise every changed group" do
    assert [_, _, _, _] =
             submit([
               open_operation("open-source", "source", 2),
               open_operation("open-a", "a", 1),
               open_operation("open-b", "b", 1),
               cash_operation("pay", "source", 3_000, 1)
             ])

    assert [_, _] =
             submit([
               transfer_operation("transfer-a", "source", "a", 500, 2, 1),
               transfer_operation("transfer-b", "source", "b", 700, 3, 1)
             ])

    assert payment("pay")["held_by_group"] == [
             %{"group_id" => "a", "amount_cents" => 500},
             %{"group_id" => "b", "amount_cents" => 700},
             %{"group_id" => "source", "amount_cents" => 1_800}
           ]

    assert [reduced] =
             submit([
               %{
                 "operation_id" => "reduce",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay",
                 "amount_cents" => 600,
                 "expected_revision" => 4
               }
             ])

    assert reduced["revision"] == 5
    assert reduced["outstanding_deposit_cents"] == 2_200
    assert get_group("a")["revision"] == 2

    assert get_group("b") |> Map.take(["revision", "cash_paid_cents"]) == %{
             "revision" => 3,
             "cash_paid_cents" => 100
           }

    assert [charged_back] =
             submit([
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay",
                 "expected_revision" => 5
               }
             ])

    assert charged_back["charged_back_cents"] == 2_400
    assert charged_back["revision"] == 6
    assert get_group("a")["revision"] == 3
    assert get_group("b")["revision"] == 4
    assert payment("pay")["held_by_group"] == []
    assert payment("pay")["held_cents"] == 0
  end

  test "chargeback reverses a transferred payment settlement on the destination group" do
    assert [_, _, _] =
             submit([
               open_operation("open-source", "source", 1),
               open_operation("open-destination", "destination", 1),
               cash_operation("pay", "source", 1_000, 1)
             ])

    assert [_, cancelled] =
             submit([
               transfer_operation("transfer", "source", "destination", 1_000, 2, 1),
               cancel_operation("cancel-destination", "destination", 2)
             ])

    assert cancelled["refunded_cents"] == 1_000
    assert ledger()["cash_refunded_cents"] == 1_000

    assert [charged_back] =
             submit([
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay",
                 "expected_revision" => 3
               }
             ])

    assert charged_back["revision"] == 4

    assert get_group("destination") |> Map.take(["revision", "status"]) == %{
             "revision" => 4,
             "status" => "cancelled"
           }

    assert ledger()["cash_refunded_cents"] == 0
    assert payment("pay")["refunded_cents"] == 0
    assert payment("pay")["charged_back_cents"] == 1_000
  end

  test "transferred credit remains paused and settles under the destination policy" do
    issue_credit("credit-source", "issue-credit", 1_000)

    assert [_, _, applied] =
             submit([
               open_operation("open-source", "source", 1),
               open_operation("open-destination", "destination", 1)
               |> Map.put("rate_plan", "advance_purchase"),
               credit_operation("apply", "source", 1_000, 1)
             ])

    assert applied["status"] == "applied"
    liability = ledger()["credit_liability_cents"]

    assert [transferred] =
             submit([transfer_operation("transfer", "source", "destination", 1_000, 2, 1)])

    assert transferred["status"] == "applied"
    assert ledger()["credit_liability_cents"] == liability

    assert [cancelled] = submit([cancel_operation("cancel-destination", "destination", 2)])
    assert cancelled["retained_cents"] == 0
    assert cancelled["credit_issued_cents"] == 0
    assert ledger()["credit_liability_cents"] == 100
  end

  test "transferred cash conversion earns the destination bonus and remains chargeable" do
    assert [_, _, _] =
             submit([
               open_operation("open-source", "source", 1),
               open_operation("open-destination", "destination", 1),
               cash_operation("pay", "source", 1_005, 1)
             ])

    assert [_, converted] =
             submit([
               transfer_operation("transfer", "source", "destination", 1_005, 2, 1),
               cancel_operation("convert", "destination", 2, "hotel_credit")
             ])

    assert converted["credit_issued_cents"] == 1_106
    assert payment("pay")["converted_to_credit_cents"] == 1_005
    assert ledger()["credit_liability_cents"] == 1_106

    assert [charged_back] =
             submit([
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay",
                 "expected_revision" => 3
               }
             ])

    assert charged_back["charged_back_cents"] == 1_005
    assert charged_back["revision"] == 4
    assert get_group("destination")["revision"] == 4
    assert payment("pay")["converted_to_credit_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
  end

  defp issue_credit(group_id, cancellation_id, amount) do
    assert [_, _, cancelled] =
             submit([
               open_operation("open-#{group_id}", group_id, 1),
               cash_operation("pay-#{group_id}", group_id, amount, 1),
               cancel_operation(cancellation_id, group_id, 2, "hotel_credit")
             ])

    assert cancelled["credit_issued_cents"] == amount + div(amount * 10 + 50, 100)
  end

  defp submit(operations) do
    conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => operations})
    json_response(conn, 200)["results"]
  end

  defp get_group(group_id) do
    json_response(get(build_conn(), "/api/v1/groups/#{group_id}"), 200)["data"]
  end

  defp payment(operation_id) do
    json_response(get(build_conn(), "/api/v1/payments/#{operation_id}"), 200)["data"]
  end

  defp ledger do
    json_response(get(build_conn(), "/api/v1/ledger?on=2026-10-06"), 200)["data"]
  end

  defp room_balances(group_id) do
    get_group(group_id)["rooms"]
    |> Enum.map(&{&1["room_id"], &1["cash_paid_cents"], &1["credit_paid_cents"]})
  end

  defp open_operation(operation_id, group_id, room_count, guest_id \\ "guest-22") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.map(1..room_count, fn index ->
          %{"room_id" => "room-#{index}", "nightly_rate_cents" => 10_000}
        end)
    }
  end

  defp cash_operation(operation_id, group_id, amount, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end

  defp credit_operation(operation_id, group_id, amount, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-06",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end

  defp transfer_operation(
         operation_id,
         source_group_id,
         destination_group_id,
         amount,
         expected_revision \\ nil,
         destination_expected_revision \\ nil
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount
    }
    |> maybe_put("expected_revision", expected_revision)
    |> maybe_put("destination_expected_revision", destination_expected_revision)
  end

  defp cancel_operation(operation_id, group_id, expected_revision, refund_method \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2026-10-06",
      "group_id" => group_id,
      "expected_revision" => expected_revision
    }
    |> maybe_put("refund_method", refund_method)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
