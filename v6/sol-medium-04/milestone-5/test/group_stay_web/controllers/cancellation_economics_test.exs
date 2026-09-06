defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-12-10",
        "departure_on" => "2027-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp submit(operations) do
    build_conn()
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp issue_credit(group_id, cancel_id, cancelled_on, cash_cents \\ 1_000) do
    [_, _, cancellation] =
      submit([
        open_operation(group_id),
        %{
          "operation_id" => "pay-#{group_id}",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => group_id,
          "amount_cents" => cash_cents
        },
        %{
          "operation_id" => cancel_id,
          "type" => "cancel_group",
          "occurred_on" => cancelled_on,
          "group_id" => group_id,
          "refund_method" => "hotel_credit"
        }
      ])

    cancellation
  end

  test "policy version follows booking date and stays fixed when rescheduled" do
    [old, new, advance] =
      submit([
        open_operation("old"),
        open_operation("new", %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        open_operation("advance", %{"rate_plan" => "advance_purchase"})
      ])

    assert old["status"] == "applied"
    assert new["status"] == "applied"
    assert advance["status"] == "applied"

    old_data =
      get(build_conn(), ~p"/api/v1/groups/old") |> json_response(200) |> Map.fetch!("data")

    new_data =
      get(build_conn(), ~p"/api/v1/groups/new") |> json_response(200) |> Map.fetch!("data")

    advance_data =
      get(build_conn(), ~p"/api/v1/groups/advance")
      |> json_response(200)
      |> Map.fetch!("data")

    assert {old_data["policy_version"], old_data["refundable_until"]} ==
             {"flex-14", "2027-11-26"}

    assert {new_data["policy_version"], new_data["refundable_until"]} ==
             {"flex-30", "2027-02-13"}

    assert {advance_data["policy_version"], advance_data["refundable_until"]} ==
             {"advance-nonrefundable", nil}

    [moved] =
      submit([
        %{
          "operation_id" => "move-new",
          "type" => "reschedule_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "new",
          "new_arrival_on" => "2027-04-20"
        }
      ])

    assert moved["policy_version"] == "flex-30"
    assert moved["refundable_until"] == "2027-03-21"
  end

  test "cash can become bonused hotel credit through its inclusive expiry date" do
    cancellation = issue_credit("source", "cancel-17", "2027-05-02", 5)

    assert cancellation == %{
             "operation_id" => "cancel-17",
             "status" => "applied",
             "group_id" => "source",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 6,
             "revision" => 3
           }

    assert get(build_conn(), ~p"/api/v1/guests/guest-22/credit?on=2028-05-01")
           |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 6,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 6,
                   "expires_on" => "2028-05-02"
                 }
               ]
             }
           }

    ledger =
      get(build_conn(), ~p"/api/v1/ledger?on=2028-05-01")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["cash_converted_to_credit_cents"] == 5
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["credit_liability_cents"] == 6

    expired =
      get(build_conn(), ~p"/api/v1/guests/guest-22/credit?on=2028-05-02")
      |> json_response(200)
      |> Map.fetch!("data")

    assert expired["available_cents"] == 0
    assert expired["lots"] == []
  end

  test "the 30-day refundable boundary is inclusive and the following day retains cash" do
    for {group_id, cancelled_on, expected_field} <- [
          {"boundary", "2027-02-13", "refunded_cents"},
          {"late", "2027-02-14", "retained_cents"}
        ] do
      [_, _, cancellation] =
        submit([
          open_operation(group_id, %{
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          }),
          %{
            "operation_id" => "pay-#{group_id}",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-01-02",
            "group_id" => group_id,
            "amount_cents" => 100
          },
          %{
            "operation_id" => "cancel-#{group_id}",
            "type" => "cancel_group",
            "occurred_on" => cancelled_on,
            "group_id" => group_id
          }
        ])

      assert cancellation[expected_field] == 100
    end
  end

  test "credit is consumed earliest-expiry first and restored to original lots" do
    assert issue_credit("source-a", "cancel-a", "2027-01-01")["credit_issued_cents"] == 1_100
    assert issue_credit("source-b", "cancel-b", "2027-02-01")["credit_issued_cents"] == 1_100

    [_, first_application, second_application] =
      submit([
        open_operation("target", %{
          "occurred_on" => "2027-03-01",
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-04"
        }),
        %{
          "operation_id" => "credit-target",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-03-02",
          "group_id" => "target",
          "amount_cents" => 500,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "credit-target-again",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-03-03",
          "group_id" => "target",
          "amount_cents" => 1_000,
          "expected_revision" => 2
        }
      ])

    assert first_application["outstanding_deposit_cents"] == 5_500
    assert first_application["revision"] == 2
    assert second_application["outstanding_deposit_cents"] == 4_500
    assert second_application["revision"] == 3

    available =
      get(build_conn(), ~p"/api/v1/guests/guest-22/credit?on=2027-03-02")
      |> json_response(200)
      |> Map.fetch!("data")

    assert available["available_cents"] == 700
    assert [%{"source_operation_id" => "cancel-b", "remaining_cents" => 700}] = available["lots"]

    [cancelled] =
      submit([
        %{
          "operation_id" => "cancel-target",
          "type" => "cancel_group",
          "occurred_on" => "2027-04-01",
          "group_id" => "target"
        }
      ])

    assert cancelled["credit_issued_cents"] == 0
    assert cancelled["refunded_cents"] == 0

    restored =
      get(build_conn(), ~p"/api/v1/guests/guest-22/credit?on=2027-04-01")
      |> json_response(200)
      |> Map.fetch!("data")

    assert restored["available_cents"] == 2_200

    assert Enum.map(restored["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) ==
             [{"cancel-a", 1_100}, {"cancel-b", 1_100}]

    target =
      get(build_conn(), ~p"/api/v1/groups/target") |> json_response(200) |> Map.fetch!("data")

    assert target["cash_paid_cents"] == 0
    assert target["credit_paid_cents"] == 0
  end

  test "mixed refundable funding bonuses only cash and restores prior credit without a second bonus" do
    issue_credit("source", "original-credit", "2027-01-01", 1_000)

    [_, _, _, cancelled] =
      submit([
        open_operation("mixed", %{
          "occurred_on" => "2027-02-01",
          "arrival_on" => "2027-12-01",
          "departure_on" => "2027-12-04"
        }),
        %{
          "operation_id" => "mixed-cash",
          "type" => "record_cash_payment",
          "occurred_on" => "2027-02-02",
          "group_id" => "mixed",
          "amount_cents" => 100
        },
        %{
          "operation_id" => "mixed-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-02-02",
          "group_id" => "mixed",
          "amount_cents" => 100
        },
        %{
          "operation_id" => "mixed-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2027-03-01",
          "group_id" => "mixed",
          "refund_method" => "hotel_credit"
        }
      ])

    assert cancelled["credit_issued_cents"] == 110
    assert cancelled["refunded_cents"] == 0
    assert cancelled["retained_cents"] == 0

    credit =
      get(build_conn(), ~p"/api/v1/guests/guest-22/credit?on=2027-03-01")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 1_210

    assert Enum.map(credit["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) ==
             [{"original-credit", 1_100}, {"mixed-cancel", 110}]
  end

  test "applied credit pauses expiry and an expired restoration removes the liability" do
    issue_credit("source", "cancel-source", "2027-01-01")

    [_, applied] =
      submit([
        open_operation("long-stay", %{
          "occurred_on" => "2027-01-02",
          "arrival_on" => "2028-03-15",
          "departure_on" => "2028-03-18"
        }),
        %{
          "operation_id" => "apply-long",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-03",
          "group_id" => "long-stay",
          "amount_cents" => 1_100
        }
      ])

    assert applied["status"] == "applied"

    after_expiry =
      get(build_conn(), ~p"/api/v1/ledger?on=2028-01-02")
      |> json_response(200)
      |> Map.fetch!("data")

    assert after_expiry["credit_liability_cents"] == 1_100

    [cancelled] =
      submit([
        %{
          "operation_id" => "cancel-long",
          "type" => "cancel_group",
          "occurred_on" => "2028-02-01",
          "group_id" => "long-stay"
        }
      ])

    assert cancelled["status"] == "applied"

    ledger =
      get(build_conn(), ~p"/api/v1/ledger?on=2028-02-01")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 0
  end

  test "non-refundable groups reject credit conversion and consume applied credit" do
    [_, _, rejected] =
      submit([
        open_operation("advance-cash", %{"rate_plan" => "advance_purchase"}),
        %{
          "operation_id" => "pay-advance",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "advance-cash",
          "amount_cents" => 1_000
        },
        %{
          "operation_id" => "bad-conversion",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "advance-cash",
          "refund_method" => "hotel_credit"
        }
      ])

    assert rejected["code"] == "refund_method_not_available"

    still_active =
      get(build_conn(), ~p"/api/v1/groups/advance-cash")
      |> json_response(200)
      |> Map.fetch!("data")

    assert still_active["status"] == "active"
    assert still_active["revision"] == 2

    issue_credit("source", "credit-for-advance", "2027-01-01")

    [_, _, cancelled] =
      submit([
        open_operation("advance-credit", %{
          "occurred_on" => "2027-01-02",
          "rate_plan" => "advance_purchase"
        }),
        %{
          "operation_id" => "apply-advance",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-03",
          "group_id" => "advance-credit",
          "amount_cents" => 1_100
        },
        %{
          "operation_id" => "cancel-advance",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-04",
          "group_id" => "advance-credit"
        }
      ])

    assert cancelled["retained_cents"] == 0
    assert cancelled["credit_issued_cents"] == 0

    ledger =
      get(build_conn(), ~p"/api/v1/ledger?on=2027-01-04")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 0
  end

  test "credit application validation and revision rules leave state unchanged" do
    issue_credit("source", "cancel-source", "2027-01-01", 100)
    submit([open_operation("target")])

    base = %{
      "operation_id" => "apply",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-02",
      "group_id" => "target"
    }

    assert [stale] =
             submit([
               base
               |> Map.put("operation_id", "apply-stale")
               |> Map.put("amount_cents", -1)
               |> Map.put("expected_revision", 99)
             ])

    assert stale["code"] == "stale_revision"

    assert [invalid] =
             submit([
               base |> Map.put("operation_id", "apply-invalid") |> Map.put("amount_cents", 0)
             ])

    assert invalid["code"] == "invalid_amount"

    assert [insufficient] =
             submit([
               base
               |> Map.put("operation_id", "apply-insufficient")
               |> Map.put("amount_cents", 111)
             ])

    assert insufficient["code"] == "insufficient_credit"

    group =
      get(build_conn(), ~p"/api/v1/groups/target") |> json_response(200) |> Map.fetch!("data")

    assert group["revision"] == 1
    assert group["deposit_paid_cents"] == 0
  end

  test "credit and ledger date parameters reject malformed dates and unknown guests read empty" do
    assert get(build_conn(), ~p"/api/v1/guests/nobody/credit?on=2027-01-01")
           |> json_response(200) == %{
             "data" => %{"guest_id" => "nobody", "available_cents" => 0, "lots" => []}
           }

    assert get(build_conn(), ~p"/api/v1/guests/nobody/credit?on=bad")
           |> json_response(422) == %{"error" => %{"code" => "invalid_date"}}

    assert get(build_conn(), ~p"/api/v1/ledger?on=bad") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_date"}}
  end
end
