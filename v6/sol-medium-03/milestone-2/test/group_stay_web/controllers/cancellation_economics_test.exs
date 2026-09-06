defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Repo
  alias GroupStay.Reservations.CreditLot

  test "fixes policy from the booking date and recomputes the cutoff on reschedule", %{conn: conn} do
    operations = [
      open_operation("old", "2026-12-31", "flexible"),
      open_operation("new", "2027-01-01", "flexible"),
      open_operation("advance", "2027-01-01", "advance_purchase"),
      %{
        "operation_id" => "move-old",
        "type" => "reschedule_group",
        "occurred_on" => "2027-01-10",
        "group_id" => "old",
        "new_arrival_on" => "2027-04-01",
        "expected_revision" => 1
      }
    ]

    results = post_batch(conn, operations)

    assert List.last(results) == %{
             "operation_id" => "move-old",
             "status" => "applied",
             "group_id" => "old",
             "new_arrival_on" => "2027-04-01",
             "new_departure_on" => "2027-04-04",
             "policy_version" => "flex-14",
             "refundable_until" => "2027-03-18",
             "revision" => 2
           }

    assert get_group("old")["policy_version"] == "flex-14"
    assert get_group("old")["refundable_until"] == "2027-03-18"
    assert get_group("new")["policy_version"] == "flex-30"
    assert get_group("new")["refundable_until"] == "2027-02-08"
    assert get_group("advance")["policy_version"] == "advance-nonrefundable"
    assert get_group("advance")["refundable_until"] == nil
  end

  test "the 30-day boundary is inclusive and the following day is non-refundable", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation("boundary", "2027-01-01", "flexible"),
        cash_payment("boundary", "pay-boundary", 100),
        cancel("boundary", "cancel-boundary", "2027-02-08"),
        open_operation("late", "2027-01-01", "flexible"),
        cash_payment("late", "pay-late", 100),
        cancel("late", "cancel-late", "2027-02-09")
      ])

    assert Enum.at(results, 2)["refunded_cents"] == 100
    assert Enum.at(results, 5)["retained_cents"] == 100
  end

  test "refundable cash can become bonused credit with inclusive expiry", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation("source", "2026-12-01", "flexible"),
        cash_payment("source", "pay", 105),
        cancel("source", "credit-cancel", "2027-02-24", "hotel_credit")
      ])

    assert List.last(results) == %{
             "operation_id" => "credit-cancel",
             "status" => "applied",
             "group_id" => "source",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 116,
             "revision" => 3
           }

    assert credit("guest-1", "2028-02-24") == %{
             "guest_id" => "guest-1",
             "available_cents" => 116,
             "lots" => [
               %{
                 "source_operation_id" => "credit-cancel",
                 "remaining_cents" => 116,
                 "expires_on" => "2028-02-24"
               }
             ]
           }

    assert credit("guest-1", "2028-02-25")["available_cents"] == 0

    assert ledger("2028-02-24") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 105,
             "credit_liability_cents" => 116
           }

    assert ledger("2028-02-25")["credit_liability_cents"] == 0
  end

  test "credit is guest-scoped, consumed by expiry then source id, and revision-safe", %{
    conn: conn
  } do
    post_batch(conn, [
      open_operation("source-z", "2026-12-01", "flexible"),
      cash_payment("source-z", "pay-z", 100),
      cancel("source-z", "zeta", "2027-02-24", "hotel_credit"),
      open_operation("source-a", "2026-12-01", "flexible"),
      cash_payment("source-a", "pay-a", 200),
      cancel("source-a", "alpha", "2027-02-24", "hotel_credit"),
      open_operation("target", "2027-01-02", "flexible")
    ])

    operations = [
      apply_credit("target", "stale", 1, 99),
      apply_credit("target", "too-much", 10_000, 1),
      apply_credit("target", "apply", 250, 1),
      apply_credit("target", "insufficient", 81, 2)
    ]

    results = post_batch(conn, operations)

    assert Enum.at(results, 0)["code"] == "stale_revision"
    assert Enum.at(results, 1)["code"] == "payment_exceeds_outstanding"

    assert Enum.at(results, 2) == %{
             "operation_id" => "apply",
             "status" => "applied",
             "group_id" => "target",
             "amount_cents" => 250,
             "outstanding_deposit_cents" => 350,
             "revision" => 2
           }

    assert Enum.at(results, 3)["code"] == "insufficient_credit"
    assert get_group("target")["revision"] == 2
    assert get_group("target")["cash_paid_cents"] == 0
    assert get_group("target")["credit_paid_cents"] == 250
    assert get_group("target")["deposit_paid_cents"] == 250

    # Equal expiries consume the lexically earlier source operation first.
    assert credit("guest-1", "2027-02-25")["lots"] == [
             %{
               "source_operation_id" => "zeta",
               "remaining_cents" => 80,
               "expires_on" => "2028-02-24"
             }
           ]

    assert credit("another-guest", "2027-02-25")["available_cents"] == 0
    assert ledger("2029-01-01")["credit_liability_cents"] == 250
  end

  test "refundable cancellation restores original credit but discards it after original expiry",
       %{
         conn: conn
       } do
    post_batch(conn, [
      open_operation("source", "2026-12-01", "flexible"),
      cash_payment("source", "pay", 100),
      cancel("source", "origin", "2027-02-01", "hotel_credit"),
      open_operation("first", "2027-01-02", "flexible", "2027-06-10"),
      apply_credit("first", "apply-first", 80, 1),
      cancel("first", "cancel-first", "2027-05-11"),
      open_operation("second", "2027-01-02", "flexible", "2028-03-10"),
      apply_credit("second", "apply-second", 100, 1)
    ])

    assert credit("guest-1", "2027-05-12")["available_cents"] == 10
    assert ledger("2028-02-02")["credit_liability_cents"] == 100

    [result] =
      post_batch(build_conn(), [cancel("second", "cancel-after-expiry", "2028-02-05")])

    assert result["credit_issued_cents"] == 0
    assert result["refunded_cents"] == 0
    assert credit("guest-1", "2028-02-05")["available_cents"] == 0
    assert ledger("2028-02-05")["credit_liability_cents"] == 0
  end

  test "hotel credit cannot bypass non-refundable policy and applied credit is consumed", %{
    conn: conn
  } do
    post_batch(conn, [
      open_operation("source", "2026-12-01", "flexible"),
      cash_payment("source", "pay", 100),
      cancel("source", "origin", "2027-02-01", "hotel_credit"),
      open_operation("advance", "2027-01-02", "advance_purchase"),
      apply_credit("advance", "fund-advance", 100, 1)
    ])

    [rejected] =
      post_batch(build_conn(), [
        cancel("advance", "not-allowed", "2027-02-02", "hotel_credit", 2)
      ])

    assert rejected["code"] == "refund_method_not_available"
    assert get_group("advance")["status"] == "active"
    assert get_group("advance")["revision"] == 2

    [cancelled] = post_batch(build_conn(), [cancel("advance", "consume", "2027-02-02")])
    assert cancelled["retained_cents"] == 0
    assert get_group("advance")["status"] == "cancelled"
    assert ledger("2027-02-02")["credit_liability_cents"] == 10
  end

  test "invalid reporting dates return a stable client error", %{conn: conn} do
    assert json_response(get(conn, "/api/v1/ledger?on=not-a-date"), 422) == %{
             "error" => %{"code" => "invalid_date"}
           }

    assert json_response(get(build_conn(), "/api/v1/guests/guest-1/credit?on=nope"), 422) == %{
             "error" => %{"code" => "invalid_date"}
           }

    assert json_response(get(build_conn(), "/api/v1/ledger?on[]=2027-01-01"), 422) == %{
             "error" => %{"code" => "invalid_date"}
           }
  end

  test "ledger liability safely exceeds SQLite's aggregate integer range", %{conn: conn} do
    Enum.each(1..5, fn index ->
      Repo.insert!(%CreditLot{
        guest_id: "large-balance",
        source_operation_id: "source-#{index}",
        remaining_cents: 2_000_000_000_000_000_000,
        expires_on: ~D[2030-01-01]
      })
    end)

    assert json_response(get(conn, "/api/v1/ledger?on=2029-01-01"), 200)["data"][
             "credit_liability_cents"
           ] == 10_000_000_000_000_000_000
  end

  defp open_operation(group_id, booked_on, rate_plan, arrival_on \\ "2027-03-10") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => booked_on,
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => arrival_on |> Date.from_iso8601!() |> Date.add(3) |> Date.to_iso8601(),
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 1_000}]
    }
  end

  defp cash_payment(group_id, operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-03",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp apply_credit(group_id, operation_id, amount, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-02-25",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end

  defp cancel(group_id, operation_id, occurred_on, method \\ nil, revision \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
    |> maybe_put("refund_method", method)
    |> maybe_put("expected_revision", revision)
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_group(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp credit(guest_id, on) do
    build_conn()
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(on) do
    build_conn()
    |> get("/api/v1/ledger?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp maybe_put(operation, _key, nil), do: operation
  defp maybe_put(operation, key, value), do: Map.put(operation, key, value)
end
