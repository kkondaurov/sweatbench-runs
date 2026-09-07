defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  describe "versioned cancellation policy" do
    test "fixes policy at booking and recomputes the deadline when rescheduled", %{conn: conn} do
      old_flexible = open_group("old", "guest", "2026-12-31", "2027-04-01")
      new_flexible = open_group("new", "guest", "2027-01-01", "2027-04-01")

      advance =
        open_group("advance", "guest", "2027-02-01", "2027-04-01")
        |> Map.put("rate_plan", "advance_purchase")

      assert %{"results" => results} =
               post_operations(conn, [old_flexible, new_flexible, advance])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-03-18"
             } = get_group("old")

      assert %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-03-02"
             } = get_group("new")

      assert %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             } = get_group("advance")

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2027-04-17",
                   "revision" => 2
                 }
               ]
             } =
               post_operations(build_conn(), [
                 %{
                   "operation_id" => "move-old",
                   "type" => "reschedule_group",
                   "occurred_on" => "2027-01-03",
                   "group_id" => "old",
                   "new_arrival_on" => "2027-05-01"
                 }
               ])
    end

    test "treats the deadline itself as refundable and applies the 30-day rule", %{conn: conn} do
      operations = [
        open_group("old", "guest", "2026-12-31", "2027-04-01"),
        cash_payment("old", "pay-old", 1_000),
        cancel("old", "cancel-old", "2027-03-18"),
        open_group("new", "guest", "2027-01-01", "2027-04-01"),
        cash_payment("new", "pay-new", 1_000),
        cancel("new", "cancel-new", "2027-03-03")
      ]

      assert %{"results" => results} = post_operations(conn, operations)
      assert Enum.at(results, 2)["refunded_cents"] == 1_000
      assert Enum.at(results, 5)["retained_cents"] == 1_000
    end
  end

  describe "hotel credit lifecycle" do
    test "converts refundable cash with a rounded bonus and reports credit and ledger totals", %{
      conn: conn
    } do
      operations = [
        open_group("source", "guest-1", "2026-10-01", "2027-04-01"),
        cash_payment("source", "source-payment", 5_005),
        cancel("source", "credit-z", "2027-03-18", "hotel_credit")
      ]

      assert %{
               "results" => [_, _, cancellation]
             } = post_operations(conn, operations)

      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 5_506,
               "revision" => 3
             } = cancellation

      assert %{
               "data" => %{
                 "guest_id" => "guest-1",
                 "available_cents" => 5_506,
                 "lots" => [
                   %{
                     "source_operation_id" => "credit-z",
                     "remaining_cents" => 5_506,
                     "expires_on" => "2028-03-17"
                   }
                 ]
               }
             } = get_credit("guest-1", "2028-03-17")

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5_005,
               "credit_liability_cents" => 5_506
             } = get_ledger("2028-03-17")

      assert %{"available_cents" => 0, "lots" => []} = get_credit("guest-1", "2028-03-18")["data"]
      assert get_ledger("2028-03-18")["credit_liability_cents"] == 0
    end

    test "applies earliest credit, pauses expiry, and drops an expired restoration", %{conn: conn} do
      issue_credit(conn, "source", "guest-1", "credit-source", 5_000)

      target = open_group("target", "guest-1", "2027-04-01", "2029-02-01")

      assert %{"results" => [_, application]} =
               post_operations(build_conn(), [
                 target,
                 apply_credit("target", "use-credit", "2027-04-02", 5_000)
               ])

      assert %{
               "status" => "applied",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 1_000,
               "revision" => 2
             } = application

      assert %{
               "deposit_paid_cents" => 5_000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 5_000
             } = get_group("target")

      assert get_credit("guest-1", "2028-03-17")["data"]["available_cents"] == 500
      assert get_ledger("2028-03-18")["credit_liability_cents"] == 5_000

      assert %{"results" => [%{"credit_issued_cents" => 0, "refunded_cents" => 0}]} =
               post_operations(build_conn(), [
                 cancel("target", "cancel-target", "2028-04-01")
               ])

      assert get_credit("guest-1", "2028-04-01")["data"]["available_cents"] == 0
      assert get_ledger("2028-04-01")["credit_liability_cents"] == 0
    end

    test "restores unexpired allocations to their original lots without a second bonus", %{
      conn: conn
    } do
      issue_credit(conn, "source", "guest-1", "original-credit", 4_000)

      post_operations(build_conn(), [
        open_group("target", "guest-1", "2027-04-01", "2027-10-20"),
        apply_credit("target", "use-credit-1", "2027-04-02", 1_000),
        apply_credit("target", "use-credit-2", "2027-04-03", 1_000),
        cancel("target", "restore-credit", "2027-09-17")
      ])

      assert %{
               "available_cents" => 4_400,
               "lots" => [
                 %{
                   "source_operation_id" => "original-credit",
                   "remaining_cents" => 4_400
                 }
               ]
             } = get_credit("guest-1", "2027-09-17")["data"]
    end

    test "consumes lots by expiry and then source operation identifier", %{conn: conn} do
      issue_credit(conn, "late", "guest-1", "z-late", 1_000)

      post_operations(build_conn(), [
        open_group("same-z", "guest-1", "2026-10-01", "2027-04-01"),
        cash_payment("same-z", "payment-same-z", 1_000),
        cancel("same-z", "z-early", "2027-03-17", "hotel_credit"),
        open_group("same-a", "guest-1", "2026-10-01", "2027-04-01"),
        cash_payment("same-a", "payment-same-a", 1_000),
        cancel("same-a", "a-early", "2027-03-17", "hotel_credit"),
        open_group("target", "guest-1", "2027-04-01", "2027-10-20"),
        apply_credit("target", "consume-ordered", "2027-04-02", 2_300)
      ])

      assert %{
               "available_cents" => 1_000,
               "lots" => [
                 %{
                   "source_operation_id" => "z-late",
                   "remaining_cents" => 1_000,
                   "expires_on" => "2028-03-17"
                 }
               ]
             } = get_credit("guest-1", "2027-04-02")["data"]
    end

    test "rejects unavailable refund methods and consumes credit on non-refundable cancellation",
         %{
           conn: conn
         } do
      issue_credit(conn, "source", "guest-1", "original-credit", 4_000)

      advance =
        open_group("advance", "guest-1", "2027-04-01", "2027-10-01")
        |> Map.put("rate_plan", "advance_purchase")

      post_operations(build_conn(), [
        advance,
        apply_credit("advance", "use-credit", "2027-04-02", 2_000)
      ])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "refund_method_not_available"
                 },
                 %{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 2},
                 %{"status" => "applied", "retained_cents" => 0, "revision" => 3}
               ]
             } =
               post_operations(build_conn(), [
                 cancel("advance", "bad-method", "2027-04-03", "hotel_credit"),
                 cancel("advance", "stale", "2027-04-03", "hotel_credit")
                 |> Map.put("expected_revision", 1),
                 cancel("advance", "consume", "2027-04-03")
               ])

      assert get_credit("guest-1", "2027-04-03")["data"]["available_cents"] == 2_400
      assert get_ledger("2027-04-03")["credit_liability_cents"] == 2_400
    end

    test "uses payment validation and rejects insufficient credit without advancing revision", %{
      conn: conn
    } do
      post_operations(conn, [open_group("target", "guest-1", "2027-01-01", "2027-10-01")])

      assert %{"results" => results} =
               post_operations(build_conn(), [
                 apply_credit("target", "invalid", "2027-01-02", 0),
                 apply_credit("target", "insufficient", "2027-01-02", 1),
                 apply_credit("target", "stale", "2027-01-02", 0)
                 |> Map.put("expected_revision", 99)
               ])

      assert Enum.map(results, & &1["code"]) == [
               "invalid_amount",
               "insufficient_credit",
               "stale_revision"
             ]

      assert get_group("target")["revision"] == 1
    end
  end

  test "date-based reads reject malformed dates", %{conn: conn} do
    assert get(conn, "/api/v1/ledger?on=nope") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_date"}}

    assert get(build_conn(), "/api/v1/guests/guest/credit?on=nope") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_date"}}
  end

  defp issue_credit(conn, group_id, guest_id, operation_id, cash) do
    post_operations(conn, [
      open_group(group_id, guest_id, "2026-10-01", "2027-04-01"),
      cash_payment(group_id, "payment-#{group_id}", cash),
      cancel(group_id, operation_id, "2027-03-18", "hotel_credit")
    ])
  end

  defp open_group(group_id, guest_id, booked_on, arrival_on) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => booked_on,
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => Date.add(Date.from_iso8601!(arrival_on), 1) |> Date.to_iso8601(),
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 30_000}]
    }
  end

  defp cash_payment(group_id, operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp apply_credit(group_id, operation_id, occurred_on, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(group_id, operation_id, occurred_on, refund_method \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
    |> then(fn operation ->
      if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation
    end)
  end

  defp post_operations(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp get_group(group_id) do
    get(build_conn(), "/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_credit(guest_id, on) do
    get(build_conn(), "/api/v1/guests/#{guest_id}/credit?on=#{on}") |> json_response(200)
  end

  defp get_ledger(on) do
    get(build_conn(), "/api/v1/ledger?on=#{on}") |> json_response(200) |> Map.fetch!("data")
  end
end
