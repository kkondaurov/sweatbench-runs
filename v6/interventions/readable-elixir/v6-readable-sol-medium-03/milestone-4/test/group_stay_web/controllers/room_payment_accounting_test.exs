defmodule GroupStayWeb.RoomPaymentAccountingTest do
  use GroupStayWeb.ConnCase

  defp post_operations(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open(group_id, guest_id \\ "guest-1") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "hotel",
      "arrival_on" => "2026-04-01",
      "departure_on" => "2026-04-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 10_000},
        %{"room_id" => "b", "nightly_rate_cents" => 20_000}
      ]
    }
  end

  defp payment(id, group_id, amount),
    do: %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-01-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }

  test "funding fills rooms in order and selected cancellation settles only those rooms" do
    assert [_, %{"status" => "applied"}, %{"status" => "applied"}] =
             post_operations([
               open("group"),
               payment("pay-1", "group", 3_000),
               payment("pay-2", "group", 1_000)
             ])

    group = get(build_conn(), "/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")

    assert [
             %{
               "room_id" => "a",
               "deposit_due_cents" => 2_000,
               "cash_paid_cents" => 2_000,
               "credit_paid_cents" => 0,
               "status" => "active"
             },
             %{
               "room_id" => "b",
               "deposit_due_cents" => 4_000,
               "cash_paid_cents" => 2_000,
               "credit_paid_cents" => 0,
               "status" => "active"
             }
           ] = group["rooms"]

    assert [
             %{
               "status" => "applied",
               "cancelled_room_ids" => ["a"],
               "refunded_cents" => 2_000,
               "revision" => 4
             }
           ] =
             post_operations([
               %{
                 "operation_id" => "cancel-a",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-03-18",
                 "group_id" => "group",
                 "room_ids" => ["a"]
               }
             ])

    group = get(build_conn(), "/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")
    assert group["lodging_total_cents"] == 20_000
    assert group["deposit_due_cents"] == 4_000
    assert group["deposit_paid_cents"] == 2_000

    assert [
             %{"status" => "cancelled", "cash_paid_cents" => 0},
             %{"status" => "active", "cash_paid_cents" => 2_000}
           ] = group["rooms"]
  end

  test "cash reductions unwind the target payment in reverse fill order and reconcile exactly" do
    post_operations([open("group"), payment("pay", "group", 5_000)])

    assert [
             %{
               "status" => "applied",
               "amount_cents" => 2_500,
               "outstanding_deposit_cents" => 3_500,
               "revision" => 3
             }
           ] =
             post_operations([
               %{
                 "operation_id" => "reduce",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-01-03",
                 "payment_operation_id" => "pay",
                 "amount_cents" => 2_500
               }
             ])

    group = get(build_conn(), "/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")
    assert [%{"cash_paid_cents" => 2_000}, %{"cash_paid_cents" => 500}] = group["rooms"]

    statement =
      get(build_conn(), "/api/v1/payments/pay") |> json_response(200) |> Map.fetch!("data")

    assert statement == %{
             "payment_operation_id" => "pay",
             "original_group_id" => "group",
             "recorded_cents" => 5_000,
             "held_cents" => 2_500,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 2_500,
             "charged_back_cents" => 0
           }

    assert %{"cash_held_cents" => 2_500, "cash_reduced_cents" => 2_500} =
             get(build_conn(), "/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  test "chargeback reclassifies converted cash and reports a shortfall for spent entitlement" do
    post_operations([
      open("source"),
      payment("pay", "source", 5_000),
      %{
        "operation_id" => "convert",
        "type" => "cancel_group",
        "occurred_on" => "2026-03-18",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      open("use"),
      %{
        "operation_id" => "use-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-03-19",
        "group_id" => "use",
        "amount_cents" => 5_500
      }
    ])

    assert [%{"status" => "applied", "charged_back_cents" => 5_000, "revision" => 4}] =
             post_operations([
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-03-20",
                 "payment_operation_id" => "pay"
               }
             ])

    ledger =
      get(build_conn(), "/api/v1/ledger?on=2026-03-20")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["cash_converted_to_credit_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 5_000
    assert ledger["credit_liability_cents"] == 5_500
    assert ledger["credit_shortfall_cents"] == 5_500
  end

  test "payment lookup distinguishes a missing receipt from a non-payment receipt" do
    post_operations([open("group")])

    assert %{"error" => %{"code" => "operation_not_found"}} =
             get(build_conn(), "/api/v1/payments/missing") |> json_response(404)

    assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
             get(build_conn(), "/api/v1/payments/open-group") |> json_response(422)
  end
end
