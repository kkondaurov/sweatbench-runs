defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  test "fixes the policy at booking and recomputes the refundable date on reschedule", %{
    conn: conn
  } do
    assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
             post_batch(conn, [open("old-policy", "2026-12-31", "2027-02-15", "flexible")])

    assert %{
             "data" => %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-02-01"
             }
           } = json_response(get(conn, "/api/v1/groups/old-policy"), 200)

    assert %{
             "results" => [
               %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-03-01",
                 "revision" => 2
               }
             ]
           } =
             post_batch(conn, [
               %{
                 "operation_id" => "move-old",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "old-policy",
                 "new_arrival_on" => "2027-03-15",
                 "expected_revision" => 1
               }
             ])

    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [open("new-policy", "2027-01-01", "2027-03-15", "flexible")])

    assert %{"data" => %{"policy_version" => "flex-30", "refundable_until" => "2027-02-13"}} =
             json_response(get(conn, "/api/v1/groups/new-policy"), 200)
  end

  test "issues, applies, and restores hotel credit while preserving the ledger liability", %{
    conn: conn
  } do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_batch(conn, [
               open("credit-source", "2026-12-31", "2027-02-15", "flexible"),
               cash_payment("source-pay", "credit-source", 100, 1, "2027-01-01"),
               cancel("source-cancel", "credit-source", 2, "2027-02-01", "hotel_credit")
             ])

    assert %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 110,
               "lots" => [
                 %{
                   "source_operation_id" => "source-cancel",
                   "remaining_cents" => 110,
                   "expires_on" => "2028-02-01"
                 }
               ]
             }
           } = json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-02-01"), 200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 100,
               "credit_liability_cents" => 110
             }
           } = json_response(get(conn, "/api/v1/ledger?on=2027-02-01"), 200)

    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [open("credit-target", "2027-01-01", "2027-04-01", "flexible")])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "amount_cents" => 100,
                 "outstanding_deposit_cents" => 100,
                 "revision" => 2
               }
             ]
           } =
             post_batch(conn, [
               %{
                 "operation_id" => "credit-use",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-02-02",
                 "group_id" => "credit-target",
                 "amount_cents" => 100,
                 "expected_revision" => 1
               }
             ])

    assert %{"data" => %{"available_cents" => 10}} =
             json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-02-02"), 200)

    assert %{"data" => %{"credit_liability_cents" => 110}} =
             json_response(get(conn, "/api/v1/ledger?on=2027-02-02"), 200)

    assert %{
             "data" => %{
               "policy_version" => "flex-30",
               "arrival_on" => "2027-04-01",
               "refundable_until" => "2027-03-02"
             }
           } = json_response(get(conn, "/api/v1/groups/credit-target"), 200)

    assert %{"results" => [%{"refunded_cents" => 0, "retained_cents" => 0, "revision" => 3}]} =
             post_batch(conn, [
               cancel("target-cancel", "credit-target", 2, "2027-03-02", "cash")
             ])

    assert %{"data" => %{"available_cents" => 110}} =
             json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-03-02"), 200)
  end

  test "rejects hotel credit for a non-refundable cancellation and insufficient credit without mutation",
       %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open("non-refundable", "2027-01-01", "2027-03-15", "flexible"),
               cash_payment("non-refundable-pay", "non-refundable", 100, 1, "2027-02-01")
             ])

    assert %{"results" => [%{"code" => "refund_method_not_available"}]} =
             post_batch(conn, [
               cancel("bad-credit-refund", "non-refundable", 2, "2027-02-14", "hotel_credit")
             ])

    assert %{"data" => %{"status" => "active", "revision" => 2}} =
             json_response(get(conn, "/api/v1/groups/non-refundable"), 200)

    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [open("empty-credit", "2027-01-01", "2027-04-01", "flexible")])

    assert %{"results" => [%{"code" => "insufficient_credit"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "empty-credit-use",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "empty-credit",
                 "amount_cents" => 1,
                 "expected_revision" => 1
               }
             ])

    assert %{"data" => %{"revision" => 1, "credit_paid_cents" => 0}} =
             json_response(get(conn, "/api/v1/groups/empty-credit"), 200)
  end

  test "expired restored credit reduces liability and is omitted from reads", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_batch(conn, [
               open("expiring-source", "2026-12-01", "2027-02-15", "flexible"),
               cash_payment("expiring-pay", "expiring-source", 100, 1, "2027-01-01"),
               cancel("expiring-cancel", "expiring-source", 2, "2027-01-01", "hotel_credit")
             ])

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open("expiring-target", "2027-01-02", "2028-03-01", "flexible"),
               %{
                 "operation_id" => "expiring-use",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "expiring-target",
                 "amount_cents" => 100,
                 "expected_revision" => 1
               }
             ])

    assert %{"results" => [%{"revision" => 3, "refunded_cents" => 0}]} =
             post_batch(conn, [
               cancel("expiring-target-cancel", "expiring-target", 2, "2028-01-02", "cash")
             ])

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2028-01-02"), 200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             json_response(get(conn, "/api/v1/ledger?on=2028-01-02"), 200)
  end

  test "rejects malformed read dates", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_date"}} =
             json_response(get(conn, "/api/v1/ledger?on=tomorrow"), 422)

    assert %{"error" => %{"code" => "invalid_date"}} =
             json_response(get(conn, "/api/v1/guests/guest-22/credit?on=tomorrow"), 422)
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open(group_id, booked_on, arrival_on, rate_plan) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => booked_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => Date.to_iso8601(Date.add(Date.from_iso8601!(arrival_on), 1)),
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 1_000}]
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents, expected_revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp cancel(operation_id, group_id, expected_revision, occurred_on, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision,
      "refund_method" => refund_method
    }
  end
end
