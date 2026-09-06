defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: true

  @moduletag :capture_log

  describe "GET /api/v1/groups/:group_id" do
    test "returns the full group representation" do
      open_default_group("group-read")

      conn = build_conn() |> get("/api/v1/groups/group-read")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "group_id" => "group-read",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "revision" => 1,
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ],
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26",
                 "outstanding_deposit_cents" => 19_500
               }
             }
    end

    test "reflects payments in the deposit totals and revision" do
      open_default_group("group-paid")
      run_and_get_results([pay_operation("group-paid", 15_000)])

      data = fetch_group("group-paid")

      assert data["deposit_paid_cents"] == 15_000
      assert data["outstanding_deposit_cents"] == 4_500
      assert data["revision"] == 2
    end

    test "returns 404 with a stable code for a missing group" do
      conn = build_conn() |> get("/api/v1/groups/no-such-group")

      assert conn.status == 404
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "identifiers are returned unchanged" do
      odd_id = "group 81 ✈ ünïcode & co"
      post_operations([open_operation(%{"group_id" => odd_id})])

      assert fetch_group(odd_id)["group_id"] == odd_id
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero" do
      conn = build_conn() |> get("/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "payments count as held cash across groups" do
      post_operations([
        open_operation(%{"operation_id" => "op-open-a", "group_id" => "group-ledger-a"}),
        open_operation(%{"operation_id" => "op-open-b", "group_id" => "group-ledger-b"}),
        pay_operation("group-ledger-a", 10_000, %{"operation_id" => "op-pay-a"}),
        pay_operation("group-ledger-b", 2_500, %{"operation_id" => "op-pay-b"})
      ])

      assert fetch_ledger() == %{
               "cash_held_cents" => 12_500,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "cancellations move held cash to refunded or retained buckets" do
      post_operations([
        open_operation(%{
          "operation_id" => "op-open-refund",
          "group_id" => "group-refund",
          "arrival_on" => "2026-12-01"
        }),
        open_operation(%{
          "operation_id" => "op-open-retain",
          "group_id" => "group-retain",
          "arrival_on" => "2026-12-01"
        }),
        pay_operation("group-refund", 10_000, %{"operation_id" => "op-pay-refund"}),
        pay_operation("group-retain", 5_000, %{"operation_id" => "op-pay-retain"}),
        cancel_operation("group-refund", %{
          "operation_id" => "op-cancel-refund",
          "occurred_on" => "2026-11-01"
        }),
        cancel_operation("group-retain", %{
          "operation_id" => "op-cancel-retain",
          "occurred_on" => "2026-11-25"
        })
      ])

      assert fetch_ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 10_000,
               "cash_retained_cents" => 5_000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end
  end

  defp run_and_get_results(operations) do
    post_operations(operations) |> json_response(200) |> Map.fetch!("results")
  end
end
