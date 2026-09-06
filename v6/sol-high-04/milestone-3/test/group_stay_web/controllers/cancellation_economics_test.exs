defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  describe "versioned cancellation policies" do
    test "fixes policy at booking and recomputes the deadline after a move", %{conn: conn} do
      operations = [
        open("old-flex", "guest", "2026-12-31", "2027-03-15"),
        open("new-flex", "guest", "2027-01-01", "2027-03-15"),
        open("advance", "guest", "2027-01-01", "2027-03-15", "advance_purchase"),
        reschedule("move-old", "old-flex", "2027-01-02", "2027-04-15")
      ]

      assert %{"results" => [_, _, _, move]} = submit(conn, operations)

      assert Map.take(move, ["policy_version", "refundable_until", "new_departure_on"]) == %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-04-01",
               "new_departure_on" => "2027-04-16"
             }

      old = get_group(conn, "old-flex")
      new = get_group(conn, "new-flex")
      advance = get_group(conn, "advance")

      assert {old["policy_version"], old["refundable_until"]} == {"flex-14", "2027-04-01"}
      assert {new["policy_version"], new["refundable_until"]} == {"flex-30", "2027-02-13"}

      assert {advance["policy_version"], advance["refundable_until"]} ==
               {"advance-nonrefundable", nil}
    end

    test "uses the fixed policy deadline inclusively", %{conn: conn} do
      submit(conn, [
        open("boundary", "guest", "2027-01-01", "2027-03-15"),
        cash("pay", "boundary", "2027-01-02", 100)
      ])

      result =
        submit(conn, [cancel("cancel", "boundary", "2027-02-13")])
        |> only_result()

      assert result["refunded_cents"] == 100
      assert result["retained_cents"] == 0
    end
  end

  describe "issuing and applying hotel credit" do
    test "converts refundable cash with a rounded bonus and later restores redeemed credit", %{
      conn: conn
    } do
      submit(conn, [
        open("source", "guest", "2026-10-01", "2027-02-01"),
        cash("source-pay", "source", "2026-10-02", 105)
      ])

      issued =
        cancel("cancel-source", "source", "2026-11-26", "hotel_credit")
        |> then(&submit(conn, [&1]))
        |> only_result()

      assert Map.take(issued, ["refunded_cents", "retained_cents", "credit_issued_cents"]) == %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 116
             }

      assert credit(conn, "guest", "2026-11-26") == %{
               "guest_id" => "guest",
               "available_cents" => 116,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-source",
                   "remaining_cents" => 116,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      assert ledger(conn, "2026-11-26") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 105,
               "credit_liability_cents" => 116
             }

      submit(conn, [open("target", "guest", "2026-12-01", "2027-02-20")])

      applied =
        credit_payment("use-credit", "target", "2026-12-02", 100, 1)
        |> then(&submit(conn, [&1]))
        |> only_result()

      assert applied["outstanding_deposit_cents"] == 900
      assert applied["revision"] == 2

      target = get_group(conn, "target")
      assert target["deposit_paid_cents"] == 100
      assert target["cash_paid_cents"] == 0
      assert target["credit_paid_cents"] == 100
      assert credit(conn, "guest", "2026-12-02")["available_cents"] == 16
      assert ledger(conn, "2026-12-02")["credit_liability_cents"] == 116

      restored =
        cancel("cancel-target", "target", "2027-01-01")
        |> then(&submit(conn, [&1]))
        |> only_result()

      assert restored["credit_issued_cents"] == 0
      assert restored["refunded_cents"] == 0
      assert credit(conn, "guest", "2027-01-01")["available_cents"] == 116
      assert ledger(conn, "2027-01-01")["credit_liability_cents"] == 116
    end

    test "consumes lots by expiry and then source operation id", %{conn: conn} do
      operations =
        source_credit_operations("later", "guest", "2026-01-02", "cancel-later") ++
          source_credit_operations("z-first-expiry", "guest", "2026-01-01", "cancel-z") ++
          source_credit_operations("a-first-expiry", "guest", "2026-01-01", "cancel-a") ++
          [
            open("target", "guest", "2026-01-05", "2026-06-01"),
            credit_payment("use", "target", "2026-01-06", 150)
          ]

      assert submit(conn, operations)["results"] |> List.last() |> Map.fetch!("status") ==
               "applied"

      assert credit(conn, "guest", "2026-01-06")["lots"] == [
               %{
                 "source_operation_id" => "cancel-z",
                 "remaining_cents" => 70,
                 "expires_on" => "2027-01-01"
               },
               %{
                 "source_operation_id" => "cancel-later",
                 "remaining_cents" => 110,
                 "expires_on" => "2027-01-02"
               }
             ]
    end

    test "rejects unavailable credit and does not advance the group revision", %{conn: conn} do
      submit(conn, [open("target", "guest", "2026-01-01", "2026-06-01")])

      insufficient =
        credit_payment("no-credit", "target", "2026-01-02", 100, 1)
        |> then(&submit(conn, [&1]))
        |> only_result()

      assert insufficient["code"] == "insufficient_credit"
      assert get_group(conn, "target")["revision"] == 1

      stale =
        credit_payment("stale", "target", "not-a-date", -1, 0)
        |> then(&submit(conn, [&1]))
        |> only_result()

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 1
    end
  end

  describe "settling credit-funded groups" do
    test "expires a restored lot immediately when its original expiry passed", %{conn: conn} do
      submit(conn, source_credit_operations("source", "guest", "2026-01-01", "cancel-source"))

      submit(conn, [
        open("target", "guest", "2026-12-01", "2027-01-30"),
        credit_payment("use", "target", "2026-12-31", 110)
      ])

      assert ledger(conn, "2027-01-02")["credit_liability_cents"] == 110

      result =
        cancel("cancel-target", "target", "2027-01-02")
        |> then(&submit(conn, [&1]))
        |> only_result()

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert credit(conn, "guest", "2027-01-02")["available_cents"] == 0
      assert ledger(conn, "2027-01-02")["credit_liability_cents"] == 0
    end

    test "consumes credit on non-refundable cancellation and rejects hotel credit as a method", %{
      conn: conn
    } do
      submit(conn, source_credit_operations("source", "guest", "2026-01-01", "cancel-source"))

      submit(conn, [
        open("target", "guest", "2026-01-03", "2026-02-01", "advance_purchase"),
        credit_payment("use", "target", "2026-01-04", 100)
      ])

      rejected =
        cancel("bad-cancel", "target", "2026-01-05", "hotel_credit")
        |> Map.put("expected_revision", 2)
        |> then(&submit(conn, [&1]))
        |> only_result()

      assert rejected["code"] == "refund_method_not_available"
      assert get_group(conn, "target")["status"] == "active"
      assert get_group(conn, "target")["revision"] == 2
      assert ledger(conn, "2026-01-05")["credit_liability_cents"] == 110

      settled =
        cancel("good-cancel", "target", "2026-01-05")
        |> Map.put("expected_revision", 2)
        |> then(&submit(conn, [&1]))
        |> only_result()

      assert settled["retained_cents"] == 0
      assert settled["revision"] == 3
      assert ledger(conn, "2026-01-05")["credit_liability_cents"] == 10
    end

    test "refunds only cash while restoring previously applied credit", %{conn: conn} do
      submit(conn, source_credit_operations("source", "guest", "2026-01-01", "cancel-source"))

      submit(conn, [
        open("target", "guest", "2026-01-03", "2026-06-01"),
        cash("cash", "target", "2026-01-04", 50),
        credit_payment("credit", "target", "2026-01-04", 100)
      ])

      result =
        cancel("cancel-target", "target", "2026-01-05", "cash")
        |> then(&submit(conn, [&1]))
        |> only_result()

      assert result["refunded_cents"] == 50
      assert result["credit_issued_cents"] == 0
      assert credit(conn, "guest", "2026-01-05")["available_cents"] == 110

      assert Map.take(ledger(conn, "2026-01-05"), [
               "cash_held_cents",
               "cash_refunded_cents",
               "cash_converted_to_credit_cents",
               "credit_liability_cents"
             ]) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 50,
               "cash_converted_to_credit_cents" => 100,
               "credit_liability_cents" => 110
             }
    end
  end

  describe "credit reads" do
    test "treats expiry as inclusive and validates the on parameter", %{conn: conn} do
      submit(conn, source_credit_operations("source", "guest", "2026-01-01", "cancel-source"))

      assert credit(conn, "guest", "2027-01-01")["available_cents"] == 110
      assert credit(conn, "guest", "2027-01-02")["available_cents"] == 0
      assert ledger(conn, "2027-01-02")["credit_liability_cents"] == 0

      conn = get(conn, "/api/v1/guests/guest/credit?on=not-a-date")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}
    end
  end

  defp source_credit_operations(group_id, guest_id, cancelled_on, cancellation_id) do
    arrival = cancelled_on |> Date.from_iso8601!() |> Date.add(60) |> Date.to_iso8601()

    [
      open(group_id, guest_id, "2025-12-01", arrival),
      cash("pay-#{group_id}", group_id, "2025-12-02", 100),
      cancel(cancellation_id, group_id, cancelled_on, "hotel_credit")
    ]
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp only_result(%{"results" => [result]}), do: result

  defp get_group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp credit(conn, guest_id, on) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn, on) do
    conn
    |> get("/api/v1/ledger?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open(group_id, guest_id, booked_on, arrival_on, rate_plan \\ "flexible") do
    departure_on = arrival_on |> Date.from_iso8601!() |> Date.add(1) |> Date.to_iso8601()

    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => booked_on,
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => departure_on,
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5_000}]
    }
  end

  defp cash(operation_id, group_id, occurred_on, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp credit_payment(operation_id, group_id, occurred_on, amount, revision \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }

    if revision, do: Map.put(operation, "expected_revision", revision), else: operation
  end

  defp reschedule(operation_id, group_id, occurred_on, arrival_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reschedule_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "new_arrival_on" => arrival_on
    }
  end

  defp cancel(operation_id, group_id, occurred_on, refund_method \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation
  end
end
