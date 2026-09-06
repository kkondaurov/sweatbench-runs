defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  defp open(group_id, guest_id, booked_on, arrival_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => booked_on,
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => arrival_on,
        "departure_on" => Date.add(Date.from_iso8601!(arrival_on), 2) |> Date.to_iso8601(),
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "one", "nightly_rate_cents" => 25_000}]
      },
      overrides
    )
  end

  defp operation(type, id, group_id, occurred_on, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "group_id" => group_id,
        "occurred_on" => occurred_on
      },
      extra
    )
  end

  defp post_operations(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  test "fixes policy at booking and recomputes its deadline after rescheduling", %{conn: conn} do
    result =
      post_operations(conn, [
        open("old", "guest", "2026-12-31", "2027-03-01"),
        open("new", "guest", "2027-01-01", "2027-03-01"),
        open("advance", "guest", "2027-02-01", "2027-03-01", %{
          "rate_plan" => "advance_purchase"
        }),
        operation("reschedule_group", "move", "old", "2027-01-01", %{
          "new_arrival_on" => "2027-04-01"
        })
      ])

    assert List.last(result["results"]) == %{
             "operation_id" => "move",
             "status" => "applied",
             "group_id" => "old",
             "new_arrival_on" => "2027-04-01",
             "new_departure_on" => "2027-04-03",
             "policy_version" => "flex-14",
             "refundable_until" => "2027-03-18",
             "revision" => 2
           }

    old = get(recycle(conn), ~p"/api/v1/groups/old") |> json_response(200) |> Map.fetch!("data")
    new = get(recycle(conn), ~p"/api/v1/groups/new") |> json_response(200) |> Map.fetch!("data")

    advance =
      get(recycle(conn), ~p"/api/v1/groups/advance")
      |> json_response(200)
      |> Map.fetch!("data")

    assert {old["policy_version"], old["refundable_until"]} == {"flex-14", "2027-03-18"}
    assert {new["policy_version"], new["refundable_until"]} == {"flex-30", "2027-01-30"}

    assert {advance["policy_version"], advance["refundable_until"]} ==
             {"advance-nonrefundable", nil}
  end

  test "converts refundable cash to bonus credit and reports expiry and ledger", %{conn: conn} do
    result =
      post_operations(conn, [
        open("source", "guest", "2027-01-02", "2027-05-01"),
        operation("record_cash_payment", "pay", "source", "2027-01-03", %{
          "amount_cents" => 5_005
        }),
        operation("cancel_group", "cancel-17", "source", "2027-04-01", %{
          "refund_method" => "hotel_credit"
        })
      ])

    assert List.last(result["results"]) == %{
             "operation_id" => "cancel-17",
             "status" => "applied",
             "group_id" => "source",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 5_506,
             "revision" => 3
           }

    assert get(recycle(conn), ~p"/api/v1/guests/guest/credit?on=2028-03-31")
           |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest",
               "available_cents" => 5_506,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 5_506,
                   "expires_on" => "2028-03-31"
                 }
               ]
             }
           }

    ledger = get(recycle(conn), ~p"/api/v1/ledger?on=2028-03-31") |> json_response(200)
    assert ledger["data"]["cash_held_cents"] == 0
    assert ledger["data"]["cash_converted_to_credit_cents"] == 5_005
    assert ledger["data"]["credit_liability_cents"] == 5_506

    assert get(recycle(conn), ~p"/api/v1/ledger?on=2028-04-01")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0
  end

  test "applies lots in expiry order and restores original lots on refundable cancellation", %{
    conn: conn
  } do
    post_operations(conn, [
      open("early-source", "guest", "2026-01-01", "2026-08-01"),
      operation("record_cash_payment", "early-pay", "early-source", "2026-01-02", %{
        "amount_cents" => 1_000
      }),
      operation("cancel_group", "z-source", "early-source", "2026-06-01", %{
        "refund_method" => "hotel_credit"
      }),
      open("late-source", "guest", "2026-01-01", "2026-09-01"),
      operation("record_cash_payment", "late-pay", "late-source", "2026-01-02", %{
        "amount_cents" => 2_000
      }),
      operation("cancel_group", "a-source", "late-source", "2026-07-01", %{
        "refund_method" => "hotel_credit"
      }),
      open("target", "guest", "2026-08-01", "2027-06-01"),
      operation("apply_hotel_credit", "apply-1", "target", "2026-08-02", %{
        "amount_cents" => 700
      }),
      operation("apply_hotel_credit", "apply-2", "target", "2026-08-02", %{
        "amount_cents" => 800
      })
    ])

    target = get(recycle(conn), ~p"/api/v1/groups/target") |> json_response(200)
    assert target["data"]["cash_paid_cents"] == 0
    assert target["data"]["credit_paid_cents"] == 1_500
    assert target["data"]["deposit_paid_cents"] == 1_500

    credit =
      get(recycle(conn), ~p"/api/v1/guests/guest/credit?on=2026-08-02") |> json_response(200)

    assert Enum.map(credit["data"]["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) ==
             [{"a-source", 1_800}]

    assert get(recycle(conn), ~p"/api/v1/ledger?on=2026-08-02")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 3_300

    post_operations(recycle(conn), [
      operation("cancel_group", "cancel-target", "target", "2027-05-02")
    ])

    restored =
      get(recycle(conn), ~p"/api/v1/guests/guest/credit?on=2027-05-02") |> json_response(200)

    assert Enum.map(restored["data"]["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) ==
             [{"z-source", 1_100}, {"a-source", 2_200}]
  end

  test "expired restored credit and non-refundable consumption reduce liability", %{conn: conn} do
    post_operations(conn, [
      open("source", "guest", "2026-01-01", "2026-03-01"),
      operation("record_cash_payment", "pay", "source", "2026-01-02", %{
        "amount_cents" => 1_000
      }),
      operation("cancel_group", "credit", "source", "2026-02-01", %{
        "refund_method" => "hotel_credit"
      }),
      open("target", "guest", "2026-03-01", "2027-04-01"),
      operation("apply_hotel_credit", "apply", "target", "2026-03-02", %{
        "amount_cents" => 1_100
      }),
      operation("cancel_group", "cancel-target", "target", "2027-03-02")
    ])

    assert get(recycle(conn), ~p"/api/v1/guests/guest/credit?on=2027-03-02")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 0

    assert get(recycle(conn), ~p"/api/v1/ledger?on=2027-03-02")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0
  end

  test "rejects unavailable refund methods and credit errors without advancing revision", %{
    conn: conn
  } do
    result =
      post_operations(conn, [
        open("advance", "guest", "2027-01-01", "2027-02-01", %{
          "rate_plan" => "advance_purchase"
        }),
        operation("cancel_group", "cancel", "advance", "2027-01-02", %{
          "refund_method" => "hotel_credit",
          "expected_revision" => 1
        }),
        operation("apply_hotel_credit", "stale", "advance", "2027-01-02", %{
          "amount_cents" => 1,
          "expected_revision" => 9
        }),
        operation("apply_hotel_credit", "empty", "advance", "2027-01-02", %{
          "amount_cents" => 1,
          "expected_revision" => 1
        })
      ])

    assert Enum.map(tl(result["results"]), & &1["code"]) == [
             "refund_method_not_available",
             "stale_revision",
             "insufficient_credit"
           ]

    group = get(recycle(conn), ~p"/api/v1/groups/advance") |> json_response(200)
    assert group["data"]["status"] == "active"
    assert group["data"]["revision"] == 1
  end
end
