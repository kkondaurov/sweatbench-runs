defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  test "fixes the policy at booking and exposes the refundable date", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_group("old", "guest-old", "2026-12-31", "2027-02-10")])

    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_group("new", "guest-new", "2027-01-01", "2027-03-01")])

    assert %{
             "data" => %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-01-27"
             }
           } = get_group(conn, "old")

    assert %{
             "data" => %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-01-30"
             }
           } = get_group(conn, "new")

    assert %{
             "results" => [
               %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-02-06"
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "move-old",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "old",
                 "new_arrival_on" => "2027-02-20"
               }
             ])
  end

  test "converts refundable cash to credit and keeps it in the ledger liability", %{conn: conn} do
    submit(conn, [open_group("source", "guest-22", "2026-12-01", "2027-01-20")])
    submit(conn, [payment("pay-source", "source", 6_000)])

    assert %{
             "results" => [
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 6_600
               }
             ]
           } =
             submit(conn, [
               cancel("cancel-source", "source", "2027-01-06")
               |> Map.put("refund_method", "hotel_credit")
             ])

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get_credit(conn, "guest-22", "2027-01-05")

    assert %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 6_600,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-source",
                   "remaining_cents" => 6_600,
                   "expires_on" => "2028-01-06"
                 }
               ]
             }
           } = get_credit(conn, "guest-22", "2028-01-06")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 6_000,
               "credit_liability_cents" => 6_600
             }
           } = get_ledger(conn, "2027-01-06")
  end

  test "consumes credit by expiry and restores the original lot on refundable cancellation", %{
    conn: conn
  } do
    submit(conn, [open_group("source-a", "guest-22", "2026-12-01", "2027-01-20")])
    submit(conn, [payment("pay-a", "source-a", 10_000)])

    submit(conn, [
      cancel("cancel-a", "source-a", "2027-01-01") |> Map.put("refund_method", "hotel_credit")
    ])

    submit(conn, [open_group("source-b", "guest-22", "2026-12-01", "2027-02-20")])
    submit(conn, [payment("pay-b", "source-b", 10_000)])

    submit(conn, [
      cancel("cancel-b", "source-b", "2027-02-01") |> Map.put("refund_method", "hotel_credit")
    ])

    submit(conn, [open_group("target", "guest-22", "2026-12-01", "2027-04-20")])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "amount_cents" => 15_000,
                 "outstanding_deposit_cents" => 15_000
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "apply-1",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-02-02",
                 "group_id" => "target",
                 "amount_cents" => 15_000
               }
             ])

    assert %{
             "data" => %{
               "available_cents" => 7_000,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-b",
                   "remaining_cents" => 7_000,
                   "expires_on" => "2028-02-01"
                 }
               ]
             }
           } = get_credit(conn, "guest-22", "2027-02-02")

    assert %{"results" => [%{"revision" => 3}]} =
             submit(conn, [cancel("cancel-target", "target", "2027-02-02")])

    assert %{
             "data" => %{
               "available_cents" => 22_000,
               "lots" => [
                 %{"source_operation_id" => "cancel-a", "remaining_cents" => 11_000},
                 %{"source_operation_id" => "cancel-b", "remaining_cents" => 11_000}
               ]
             }
           } = get_credit(conn, "guest-22", "2027-02-02")
  end

  test "does not restore credit that expired while it funded a group", %{conn: conn} do
    submit(conn, [open_group("source", "guest-22", "2026-12-01", "2027-01-20")])
    submit(conn, [payment("pay-source", "source", 6_000)])

    submit(conn, [
      cancel("cancel-source", "source", "2027-01-01") |> Map.put("refund_method", "hotel_credit")
    ])

    submit(conn, [open_group("target", "guest-22", "2026-12-01", "2028-01-21")])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "apply-all",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "target",
                 "amount_cents" => 6_600
               }
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [cancel("cancel-target", "target", "2028-01-07")])

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get_credit(conn, "guest-22", "2028-01-07")

    assert %{"data" => %{"credit_liability_cents" => 0}} = get_ledger(conn, "2028-01-07")
  end

  test "rejects hotel credit for non-refundable groups and consumes credit on non-refundable cancellation",
       %{
         conn: conn
       } do
    submit(conn, [open_group("source", "guest-22", "2026-12-01", "2027-01-20")])
    submit(conn, [payment("pay-source", "source", 6_000)])

    submit(conn, [
      cancel("cancel-source", "source", "2027-01-01") |> Map.put("refund_method", "hotel_credit")
    ])

    submit(conn, [
      open_group("advance", "guest-22", "2027-01-01", "2027-03-20")
      |> Map.put("rate_plan", "advance_purchase")
    ])

    assert %{
             "results" => [
               %{
                 "status" => "rejected",
                 "code" => "refund_method_not_available"
               }
             ]
           } =
             submit(conn, [
               cancel("bad-credit-refund", "advance", "2027-01-02")
               |> Map.put("refund_method", "hotel_credit")
             ])

    assert %{"data" => %{"status" => "active", "revision" => 1}} = get_group(conn, "advance")

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "apply-advance",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "advance",
                 "amount_cents" => 6_600
               }
             ])

    assert %{"results" => [%{"retained_cents" => 0, "credit_issued_cents" => 0}]} =
             submit(conn, [cancel("cancel-advance", "advance", "2027-01-03")])

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} = get_credit(conn, "guest-22")
    assert %{"data" => %{"credit_liability_cents" => 0}} = get_ledger(conn)
  end

  test "credit validation is revision-safe", %{conn: conn} do
    submit(conn, [open_group("target", "guest-22", "2027-01-01", "2027-03-20")])

    assert %{"results" => [%{"code" => "insufficient_credit", "status" => "rejected"}]} =
             submit(conn, [
               %{
                 "operation_id" => "apply-missing",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "target",
                 "amount_cents" => 1,
                 "expected_revision" => 1
               }
             ])

    assert %{"results" => [%{"revision" => 2}]} = submit(conn, [payment("pay", "target", 1)])

    assert %{
             "results" => [
               %{
                 "code" => "stale_revision",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "apply-stale",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "target",
                 "amount_cents" => 1,
                 "expected_revision" => 1
               }
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
      "departure_on" => Date.add(Date.from_iso8601!(arrival_on), 3) |> Date.to_iso8601(),
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 50_000}]
    }
  end

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp get_group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  defp get_credit(conn, guest_id, on \\ nil) do
    path = "/api/v1/guests/#{guest_id}/credit" <> if(on, do: "?on=#{on}", else: "")

    conn
    |> get(path)
    |> json_response(200)
  end

  defp get_ledger(conn, on \\ nil) do
    path = "/api/v1/ledger" <> if(on, do: "?on=#{on}", else: "")

    conn
    |> get(path)
    |> json_response(200)
  end
end
