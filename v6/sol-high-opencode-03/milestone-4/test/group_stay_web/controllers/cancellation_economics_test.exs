defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  test "fixes policy at booking and recomputes the cutoff when rescheduled" do
    assert [old_flex, new_flex, advance] =
             submit([
               open_operation("open-old", "old-flex", %{
                 "occurred_on" => "2026-12-31",
                 "arrival_on" => "2027-03-10",
                 "departure_on" => "2027-03-11"
               }),
               open_operation("open-new", "new-flex", %{
                 "occurred_on" => "2027-01-01",
                 "arrival_on" => "2027-03-10",
                 "departure_on" => "2027-03-11"
               }),
               open_operation("open-advance", "advance", %{
                 "occurred_on" => "2027-01-01",
                 "rate_plan" => "advance_purchase"
               })
             ])

    assert old_flex["status"] == "applied"
    assert new_flex["status"] == "applied"
    assert advance["status"] == "applied"

    assert get_group("old-flex")
           |> Map.take(["policy_version", "refundable_until"]) == %{
             "policy_version" => "flex-14",
             "refundable_until" => "2027-02-24"
           }

    assert get_group("new-flex")
           |> Map.take(["policy_version", "refundable_until"]) == %{
             "policy_version" => "flex-30",
             "refundable_until" => "2027-02-08"
           }

    assert get_group("advance")
           |> Map.take(["policy_version", "refundable_until"]) == %{
             "policy_version" => "advance-nonrefundable",
             "refundable_until" => nil
           }

    assert [move] =
             submit([
               %{
                 "operation_id" => "move-old",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "old-flex",
                 "new_arrival_on" => "2027-04-01",
                 "expected_revision" => 1
               }
             ])

    assert move
           |> Map.take(["policy_version", "refundable_until", "revision"]) == %{
             "policy_version" => "flex-14",
             "refundable_until" => "2027-03-18",
             "revision" => 2
           }
  end

  test "uses the policy cutoff date inclusively" do
    assert [_, _, refundable, _, _, retained] =
             submit([
               open_operation("open-at-cutoff", "at-cutoff", %{
                 "occurred_on" => "2027-01-01",
                 "arrival_on" => "2027-03-10",
                 "departure_on" => "2027-03-11"
               }),
               cash_operation("pay-at-cutoff", "at-cutoff", 1_000, "2027-01-02", 1),
               cancel_operation("cancel-at-cutoff", "at-cutoff", "2027-02-08", 2),
               open_operation("open-late", "late", %{
                 "occurred_on" => "2027-01-01",
                 "arrival_on" => "2027-03-10",
                 "departure_on" => "2027-03-11"
               }),
               cash_operation("pay-late", "late", 1_000, "2027-01-02", 1),
               cancel_operation("cancel-late", "late", "2027-02-09", 2)
             ])

    assert refundable
           |> Map.take(["refunded_cents", "retained_cents", "credit_issued_cents"]) == %{
             "refunded_cents" => 1_000,
             "retained_cents" => 0,
             "credit_issued_cents" => 0
           }

    assert retained
           |> Map.take(["refunded_cents", "retained_cents", "credit_issued_cents"]) == %{
             "refunded_cents" => 0,
             "retained_cents" => 1_000,
             "credit_issued_cents" => 0
           }
  end

  test "converts refundable cash to a bonused credit lot and reports dated liability" do
    assert [_, _, cancellation] =
             submit([
               open_operation("open-source", "source", %{
                 "arrival_on" => "2026-12-20",
                 "departure_on" => "2026-12-21"
               }),
               cash_operation("pay-source", "source", 1_005, "2026-10-04", 1),
               cancel_operation(
                 "cancel-source",
                 "source",
                 "2026-10-05",
                 2,
                 "hotel_credit"
               )
             ])

    assert cancellation
           |> Map.take([
             "refunded_cents",
             "retained_cents",
             "credit_issued_cents",
             "revision"
           ]) == %{
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 1_106,
             "revision" => 3
           }

    assert credit("guest-22", "2027-10-05") == %{
             "guest_id" => "guest-22",
             "available_cents" => 1_106,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-source",
                 "remaining_cents" => 1_106,
                 "expires_on" => "2027-10-05"
               }
             ]
           }

    assert credit("guest-22", "2027-10-06")["available_cents"] == 0
    assert credit("guest-22", "2026-10-04")["available_cents"] == 0

    assert ledger("2027-10-05") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 1_005,
             "credit_liability_cents" => 1_106,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    assert ledger("2027-10-06")["credit_liability_cents"] == 0
  end

  test "consumes lots in expiry and source order and restores original lots" do
    issue_credit("source-b", "cancel-b", "2026-10-05", 1_000)
    issue_credit("source-a", "cancel-a", "2026-10-05", 1_000)

    assert credit("guest-22", "2026-10-06")["lots"]
           |> Enum.map(& &1["source_operation_id"]) == ["cancel-a", "cancel-b"]

    assert [_, apply_result] =
             submit([
               open_operation("open-target", "target", %{
                 "occurred_on" => "2026-10-06",
                 "arrival_on" => "2027-03-01",
                 "departure_on" => "2027-03-02"
               }),
               credit_operation("apply-credit", "target", 1_500, "2026-10-07", 1)
             ])

    assert apply_result == %{
             "operation_id" => "apply-credit",
             "status" => "applied",
             "group_id" => "target",
             "amount_cents" => 1_500,
             "outstanding_deposit_cents" => 500,
             "revision" => 2
           }

    assert get_group("target")
           |> Map.take([
             "deposit_paid_cents",
             "cash_paid_cents",
             "credit_paid_cents",
             "outstanding_deposit_cents"
           ]) == %{
             "deposit_paid_cents" => 1_500,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 1_500,
             "outstanding_deposit_cents" => 500
           }

    assert credit("guest-22", "2026-10-07")["lots"] == [
             %{
               "source_operation_id" => "cancel-b",
               "remaining_cents" => 700,
               "expires_on" => "2027-10-05"
             }
           ]

    assert ledger("2026-10-07")["credit_liability_cents"] == 2_200
    assert ledger("2026-10-04")["credit_liability_cents"] == 0

    assert [cancellation] =
             submit([
               cancel_operation("cancel-target", "target", "2027-01-01", 2)
             ])

    assert cancellation
           |> Map.take(["refunded_cents", "retained_cents", "credit_issued_cents"]) == %{
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 0
           }

    assert credit("guest-22", "2027-01-01")["lots"]
           |> Enum.map(&{&1["source_operation_id"], &1["remaining_cents"]}) == [
             {"cancel-a", 1_100},
             {"cancel-b", 1_100}
           ]
  end

  test "refunds only cash and immediately expires restored credit past its original expiry" do
    issue_credit("old-source", "old-credit", "2026-01-01", 1_000)

    assert [_, applied, paid, cancelled] =
             submit([
               open_operation("open-target", "target", %{
                 "occurred_on" => "2026-12-01",
                 "arrival_on" => "2027-03-01",
                 "departure_on" => "2027-03-02"
               }),
               credit_operation("apply-old", "target", 500, "2027-01-01", 1),
               cash_operation("pay-target", "target", 500, "2027-01-01", 2),
               cancel_operation("cancel-target", "target", "2027-01-02", 3)
             ])

    assert applied["status"] == "applied"
    assert paid["status"] == "applied"

    assert cancelled
           |> Map.take(["refunded_cents", "retained_cents", "credit_issued_cents"]) == %{
             "refunded_cents" => 500,
             "retained_cents" => 0,
             "credit_issued_cents" => 0
           }

    assert credit("guest-22", "2027-01-02")["available_cents"] == 0
    assert ledger("2027-01-02")["credit_liability_cents"] == 0
  end

  test "rejects hotel credit for non-refundable cancellation and consumes applied credit" do
    issue_credit("source", "source-cancel", "2026-10-01", 1_000)

    assert [_, applied, paid, stale, unavailable, cancelled] =
             submit([
               open_operation("open-advance", "advance", %{
                 "occurred_on" => "2026-10-02",
                 "rate_plan" => "advance_purchase",
                 "arrival_on" => "2027-03-01",
                 "departure_on" => "2027-03-02"
               }),
               credit_operation("apply", "advance", 500, "2026-10-03", 1),
               cash_operation("pay", "advance", 500, "2026-10-03", 2),
               cancel_operation("stale", "advance", "2026-10-04", 1, "hotel_credit"),
               cancel_operation("unavailable", "advance", "2026-10-04", 3, "hotel_credit"),
               cancel_operation("cancel", "advance", "2026-10-04", 3)
             ])

    assert applied["status"] == "applied"
    assert paid["status"] == "applied"
    assert stale["code"] == "stale_revision"
    assert unavailable["code"] == "refund_method_not_available"

    assert cancelled
           |> Map.take(["refunded_cents", "retained_cents", "credit_issued_cents", "revision"]) ==
             %{
               "refunded_cents" => 0,
               "retained_cents" => 500,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

    assert get_group("advance")["status"] == "cancelled"
    assert credit("guest-22", "2026-10-04")["available_cents"] == 600
    assert ledger("2026-10-04")["credit_liability_cents"] == 600
  end

  test "credit payment validations reject atomically without advancing revision" do
    assert [_, stale, invalid, exceeds, insufficient] =
             submit([
               open_operation("open", "target"),
               credit_operation("stale", "target", -1, "2026-10-04", 9),
               credit_operation("invalid", "target", 0, "2026-10-04", 1),
               credit_operation("exceeds", "target", 99_999, "2026-10-04", 1),
               credit_operation("insufficient", "target", 1, "2026-10-04", 1)
             ])

    assert stale["code"] == "stale_revision"
    assert invalid["code"] == "invalid_amount"
    assert exceeds["code"] == "payment_exceeds_outstanding"
    assert insufficient["code"] == "insufficient_credit"
    assert get_group("target")["revision"] == 1
  end

  test "serializes attempts to spend the same credit lot" do
    issue_credit("source", "source-cancel", "2026-10-01", 1_000)

    assert [%{"status" => "applied"}, %{"status" => "applied"}] =
             submit([
               open_operation("open-one", "target-one"),
               open_operation("open-two", "target-two")
             ])

    operations = [
      credit_operation("apply-one", "target-one", 1_000, "2026-10-04", 1),
      credit_operation("apply-two", "target-two", 1_000, "2026-10-04", 1)
    ]

    results =
      operations
      |> Enum.map(fn operation ->
        Task.async(fn -> GroupStay.Operations.submit([operation]) |> List.first() end)
      end)
      |> Task.await_many()

    assert Enum.sort(Enum.map(results, &{&1.status, &1[:code]})) == [
             {"applied", nil},
             {"rejected", "insufficient_credit"}
           ]

    assert credit("guest-22", "2026-10-04")["available_cents"] == 100
  end

  test "dated read endpoints reject invalid dates and unknown guests return an empty balance" do
    assert credit("unknown", "2026-01-01") == %{
             "guest_id" => "unknown",
             "available_cents" => 0,
             "lots" => []
           }

    for path <- ["/api/v1/guests/unknown/credit?on=nope", "/api/v1/ledger?on=nope"] do
      assert json_response(get(build_conn(), path), 422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end

  defp issue_credit(group_id, cancellation_id, cancelled_on, cash_cents) do
    arrival_on = cancelled_on |> Date.from_iso8601!() |> Date.add(60) |> Date.to_iso8601()
    departure_on = arrival_on |> Date.from_iso8601!() |> Date.add(1) |> Date.to_iso8601()

    assert [opened, paid, cancelled] =
             submit([
               open_operation("open-#{group_id}", group_id, %{
                 "occurred_on" => cancelled_on,
                 "arrival_on" => arrival_on,
                 "departure_on" => departure_on
               }),
               cash_operation("pay-#{group_id}", group_id, cash_cents, cancelled_on, 1),
               cancel_operation(cancellation_id, group_id, cancelled_on, 2, "hotel_credit")
             ])

    assert opened["status"] == "applied"
    assert paid["status"] == "applied"
    assert cancelled["status"] == "applied"
  end

  defp submit(operations) do
    conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => operations})
    json_response(conn, 200)["results"]
  end

  defp get_group(group_id) do
    json_response(get(build_conn(), "/api/v1/groups/#{group_id}"), 200)["data"]
  end

  defp credit(guest_id, on) do
    json_response(get(build_conn(), "/api/v1/guests/#{guest_id}/credit?on=#{on}"), 200)["data"]
  end

  defp ledger(on) do
    json_response(get(build_conn(), "/api/v1/ledger?on=#{on}"), 200)["data"]
  end

  defp open_operation(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp cash_operation(operation_id, group_id, amount_cents, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp credit_operation(operation_id, group_id, amount_cents, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp cancel_operation(
         operation_id,
         group_id,
         occurred_on,
         expected_revision,
         refund_method \\ nil
       ) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision
    }

    if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation
  end
end
