defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  describe "policy versions" do
    test "fixes policy at booking and recomputes its deadline when rescheduled", %{conn: conn} do
      operations = [
        open_operation("old", "guest-old", "2026-12-31", "2027-03-10"),
        open_operation("new", "guest-new", "2027-01-01", "2027-03-10"),
        open_operation("advance", "guest-advance", "2027-01-01", "2027-03-10", %{
          "rate_plan" => "advance_purchase"
        }),
        %{
          "operation_id" => "move-old",
          "type" => "reschedule_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "old",
          "new_arrival_on" => "2027-04-10",
          "expected_revision" => 1
        }
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => [_, _, _, moved]} = json_response(conn, 200)
      assert moved["policy_version"] == "flex-14"
      assert moved["refundable_until"] == "2027-03-27"

      assert get_group(conn, "old") |> Map.take(["policy_version", "refundable_until"]) == %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-03-27"
             }

      assert get_group(conn, "new") |> Map.take(["policy_version", "refundable_until"]) == %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-02-08"
             }

      assert get_group(conn, "advance")
             |> Map.take(["policy_version", "refundable_until"]) == %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             }
    end
  end

  describe "hotel credit lifecycle" do
    test "converts refundable cash with a rounded bonus and pauses redeemed credit expiry", %{
      conn: conn
    } do
      operations = [
        open_operation("source", "guest-1", "2026-12-01", "2027-02-15"),
        cash_payment("source-pay", "source", 5_001, 1, "2026-12-02"),
        cancellation("credit-me", "source", "2027-01-01", 2, "hotel_credit"),
        open_operation("target", "guest-1", "2027-01-02", "2028-03-05"),
        credit_payment("use-credit", "target", 3_000, 1, "2027-01-03")
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => [_, _, cancelled, _, applied]} = json_response(conn, 200)

      assert cancelled["refunded_cents"] == 0
      assert cancelled["retained_cents"] == 0
      assert cancelled["credit_issued_cents"] == 5_501
      assert applied["outstanding_deposit_cents"] == 3_500
      assert applied["revision"] == 2

      target = get_group(conn, "target")
      assert target["deposit_paid_cents"] == 3_000
      assert target["cash_paid_cents"] == 0
      assert target["credit_paid_cents"] == 3_000

      assert %{
               "available_cents" => 2_501,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-me",
                   "remaining_cents" => 2_501,
                   "expires_on" => "2028-01-01"
                 }
               ]
             } = get_credit(conn, "guest-1", "2027-06-01")

      ledger = get_ledger(conn, "2028-01-02")
      assert ledger["cash_converted_to_credit_cents"] == 5_001
      assert ledger["cash_held_cents"] == 0
      assert ledger["credit_liability_cents"] == 3_000

      conn =
        post(recycle(conn), ~p"/api/v1/partner-batches", %{
          operations: [cancellation("cancel-target", "target", "2028-02-01", 2, "cash")]
        })

      assert %{"results" => [%{"status" => "applied", "credit_issued_cents" => 0}]} =
               json_response(conn, 200)

      assert get_credit(conn, "guest-1", "2028-02-01")["available_cents"] == 0
      assert get_ledger(conn, "2028-02-01")["credit_liability_cents"] == 0
    end

    test "restores redeemed lots on a timely cancellation without another bonus", %{conn: conn} do
      operations = [
        open_operation("source", "guest-1", "2026-10-01", "2027-05-01"),
        cash_payment("pay", "source", 1_000, 1, "2026-10-02"),
        cancellation("issue", "source", "2026-10-03", 2, "hotel_credit"),
        open_operation("target", "guest-1", "2026-10-04", "2027-06-01"),
        credit_payment("apply", "target", 1_100, 1, "2026-10-05"),
        cancellation("restore", "target", "2026-10-06", 2, "cash")
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 5)["credit_issued_cents"] == 0

      assert %{"available_cents" => 1_100, "lots" => [lot]} =
               get_credit(conn, "guest-1", "2026-10-06")

      assert lot["source_operation_id"] == "issue"
      assert lot["expires_on"] == "2027-10-03"
      assert get_ledger(conn, "2026-10-06")["credit_liability_cents"] == 1_100
    end

    test "rejects hotel credit for non-refundable cancellation without changing revision", %{
      conn: conn
    } do
      operations = [
        open_operation("group", "guest", "2027-01-01", "2027-02-15"),
        cash_payment("pay", "group", 500, 1, "2027-01-02"),
        cancellation("too-late", "group", "2027-01-20", 2, "hotel_credit")
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => [_, _, rejected]} = json_response(conn, 200)
      assert rejected["code"] == "refund_method_not_available"
      assert get_group(conn, "group")["revision"] == 2
      assert get_group(conn, "group")["status"] == "active"
      assert get_ledger(conn, "2027-01-20")["cash_held_cents"] == 500
    end

    test "consumes available lots by expiry and source operation identifier", %{conn: conn} do
      operations =
        Enum.flat_map([{"a-group", "a-lot"}, {"b-group", "b-lot"}], fn {group, cancel} ->
          [
            open_operation(group, "guest", "2026-01-01", "2027-06-01"),
            cash_payment("pay-#{group}", group, 500, 1, "2026-01-02"),
            cancellation(cancel, group, "2026-02-01", 2, "hotel_credit")
          ]
        end) ++
          [
            open_operation("target", "guest", "2026-02-02", "2027-06-01"),
            credit_payment("redeem", "target", 600, 1, "2026-02-03")
          ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: operations})
      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      assert %{"available_cents" => 500, "lots" => [lot]} =
               get_credit(conn, "guest", "2026-02-03")

      assert lot["source_operation_id"] == "b-lot"
      assert lot["remaining_cents"] == 500
    end

    test "consumes applied credit on non-refundable cancellation and keeps rejections atomic", %{
      conn: conn
    } do
      operations = [
        open_operation("source", "guest", "2026-01-01", "2027-06-01"),
        cash_payment("pay", "source", 1_000, 1, "2026-01-02"),
        cancellation("issue", "source", "2026-02-01", 2, "hotel_credit"),
        open_operation("target", "guest", "2026-02-02", "2027-06-01", %{
          "rate_plan" => "advance_purchase"
        }),
        credit_payment("apply", "target", 1_100, 1, "2026-02-03"),
        credit_payment("stale", "target", 99_999, 1, "2026-02-04"),
        credit_payment("insufficient", "target", 1, 2, "2026-02-04"),
        cancellation("forfeit", "target", "2026-02-05", 2, "cash")
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 5)["code"] == "stale_revision"
      assert Enum.at(results, 6)["code"] == "insufficient_credit"
      assert Enum.at(results, 7)["retained_cents"] == 0
      assert Enum.at(results, 7)["revision"] == 3
      assert get_ledger(conn, "2026-02-05")["credit_liability_cents"] == 0
      assert get_group(conn, "target")["revision"] == 3
    end
  end

  defp open_operation(group_id, guest_id, booked_on, arrival_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => booked_on,
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => arrival_on,
        "departure_on" => arrival_on |> Date.from_iso8601!() |> Date.add(2) |> Date.to_iso8601(),
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 16_250}]
      },
      overrides
    )
  end

  defp cash_payment(operation_id, group_id, amount, revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp credit_payment(operation_id, group_id, amount, revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp cancellation(operation_id, group_id, occurred_on, revision, method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => method,
      "expected_revision" => revision
    }
  end

  defp get_group(conn, group_id) do
    get(recycle(conn), "/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_credit(conn, guest_id, on) do
    get(recycle(conn), "/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_ledger(conn, on) do
    get(recycle(conn), "/api/v1/ledger?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end
end
