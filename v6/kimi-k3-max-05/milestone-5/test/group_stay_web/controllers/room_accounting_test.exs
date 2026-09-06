defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, body) do
    post(conn, ~p"/api/v1/partner-batches", body)
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp credit_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-21",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp cancel_rooms_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-20",
        "group_id" => "group-81",
        "room_ids" => ["room-b"]
      },
      overrides
    )
  end

  defp get_group(group_id) do
    conn = get(build_conn(), ~p"/api/v1/groups/#{group_id}")
    json_response(conn, 200)["data"]
  end

  defp get_ledger(query \\ "") do
    conn = get(build_conn(), "/api/v1/ledger" <> query)
    json_response(conn, 200)["data"]
  end

  defp get_credit(guest_id, query \\ "") do
    conn = get(build_conn(), "/api/v1/guests/#{guest_id}/credit" <> query)
    json_response(conn, 200)["data"]
  end

  # Opens and funds a flexible group for the guest, then cancels it into a
  # hotel credit lot of `cash_cents` + 10%.
  defp issue_credit(conn, guest_id, group_id, cash_cents) do
    operations = [
      open_op(%{
        "operation_id" => "op-open-#{group_id}",
        "group_id" => group_id,
        "guest_id" => guest_id
      }),
      payment_op(%{
        "operation_id" => "op-pay-#{group_id}",
        "group_id" => group_id,
        "amount_cents" => cash_cents
      }),
      %{
        "operation_id" => "op-cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      }
    ]

    conn = post_batch(conn, %{"operations" => operations})
    assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)
  end

  describe "room-level accounting" do
    test "cash fills room deposits in the rooms' original order", %{conn: conn} do
      operations = [
        open_op(),
        # fills room-a's 9_000 deposit exactly
        payment_op(%{"amount_cents" => 9_000}),
        # spills into room-b
        payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 5_000})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _]} = json_response(conn, 200)

      group = get_group("group-81")

      assert [
               %{
                 "room_id" => "room-a",
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 9_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 5_000,
                 "credit_paid_cents" => 0
               }
             ] = group["rooms"]

      assert group["deposit_paid_cents"] == 14_000
      assert group["cash_paid_cents"] == 14_000
      assert group["outstanding_deposit_cents"] == 5_500
    end

    test "cash and credit interleave in room order", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        credit_op(%{"amount_cents" => 4_000, "occurred_on" => "2026-11-22"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)

      group = get_group("group-81")

      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 9_000, "credit_paid_cents" => 0},
               %{"room_id" => "room-b", "cash_paid_cents" => 1_000, "credit_paid_cents" => 4_000}
             ] = group["rooms"]

      assert group["cash_paid_cents"] == 10_000
      assert group["credit_paid_cents"] == 4_000
      assert group["outstanding_deposit_cents"] == 5_500
    end
  end

  describe "cancel_rooms" do
    test "settles the selected rooms and leaves the rest untouched", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 19_500}),
        cancel_rooms_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 10_500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      group = get_group("group-81")

      assert [
               %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 9_000},
               %{
                 "room_id" => "room-b",
                 "status" => "cancelled",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 0
               }
             ] = group["rooms"]

      # totals describe the active rooms only
      assert group["status"] == "active"
      assert group["lodging_total_cents"] == 45_000
      assert group["deposit_due_cents"] == 9_000
      assert group["deposit_paid_cents"] == 9_000
      assert group["outstanding_deposit_cents"] == 0

      assert %{"cash_held_cents" => 9_000, "cash_refunded_cents" => 10_500} = get_ledger()
    end

    test "cancel_group afterwards settles only the remaining rooms", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 19_500}),
        cancel_rooms_op(),
        %{
          "operation_id" => "op-cancel-all",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-21",
          "group_id" => "group-81"
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-cancel-all",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 9_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      group = get_group("group-81")
      assert group["status"] == "cancelled"
      assert group["deposit_paid_cents"] == 0

      assert %{"cash_refunded_cents" => 19_500, "cash_held_cents" => 0} = get_ledger()
    end

    test "returns cancelled_room_ids in the group's original room order", %{conn: conn} do
      operations = [
        open_op(),
        cancel_rooms_op(%{"room_ids" => ["room-b", "room-a"]})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["cancelled_room_ids"] == ["room-a", "room-b"]

      # no active rooms remain, so the group is cancelled
      assert get_group("group-81")["status"] == "cancelled"
    end

    test "unpaid deposit for the selected rooms ceases to be due", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 9_000}),
        cancel_rooms_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      # room-b held no cash
      assert result["refunded_cents"] == 0

      group = get_group("group-81")
      assert group["deposit_due_cents"] == 9_000
      assert group["outstanding_deposit_cents"] == 0
    end

    test "computes the hotel-credit bonus once on the combined cash", %{conn: conn} do
      # two rooms with a 1_005 deposit each: a per-room bonus would round
      # 100.5 up to 101 twice (2_212 total); the combined 2_010 yields 2_211
      operations = [
        open_op(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 5_025},
            %{"room_id" => "room-b", "nightly_rate_cents" => 5_025}
          ]
        }),
        payment_op(%{"amount_cents" => 2_010}),
        cancel_rooms_op(%{
          "room_ids" => ["room-a", "room-b"],
          "refund_method" => "hotel_credit"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["credit_issued_cents"] == 2_211
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      assert get_credit("guest-22")["available_cents"] == 2_211
      assert %{"cash_converted_to_credit_cents" => 2_010} = get_ledger()
    end

    test "retains selected rooms' cash on a non-refundable cancellation", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 19_500}),
        # 13 days before arrival: inside the flex-14 window
        cancel_rooms_op(%{"occurred_on" => "2026-11-27"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 10_500

      assert %{"cash_retained_cents" => 10_500, "cash_held_cents" => 9_000} = get_ledger()
    end

    test "restores only the selected rooms' credit to its lot", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(),
        credit_op(%{"amount_cents" => 9_500, "occurred_on" => "2026-11-22"}),
        cancel_rooms_op(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-23"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0

      # room-a held 9_000 of credit (restored); room-b keeps its 500
      group = get_group("group-81")

      assert [
               %{"room_id" => "room-a", "status" => "cancelled", "credit_paid_cents" => 0},
               %{"room_id" => "room-b", "status" => "active", "credit_paid_cents" => 500}
             ] = group["rooms"]

      assert %{"available_cents" => 10_500} = get_credit("guest-22")
      assert %{"credit_liability_cents" => 11_000} = get_ledger()
    end

    test "consumes selected rooms' credit on a non-refundable cancellation", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(),
        credit_op(%{"amount_cents" => 5_000, "occurred_on" => "2026-11-22"}),
        # inside the window: non-refundable
        cancel_rooms_op(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-27"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"

      # room-a's 5_000 of credit is consumed; the remaining 6_000 of the lot
      # is untouched
      assert %{"available_cents" => 6_000} = get_credit("guest-22")
      assert %{"credit_liability_cents" => 6_000} = get_ledger()
    end

    test "rejects hotel credit for a non-refundable room cancellation", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 19_500}),
        cancel_rooms_op(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["code"] == "refund_method_not_available"

      group = get_group("group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2
      assert Enum.all?(group["rooms"], &(&1["status"] == "active"))
    end

    test "rejects room identifiers that are not distinct active rooms of the group", %{
      conn: conn
    } do
      operations = [
        open_op(),
        cancel_rooms_op(%{"operation_id" => "op-1", "room_ids" => ["room-a", "room-a"]}),
        cancel_rooms_op(%{"operation_id" => "op-2", "room_ids" => ["room-zz"]}),
        cancel_rooms_op(%{"operation_id" => "op-3", "room_ids" => []}),
        cancel_rooms_op(%{"operation_id" => "op-4", "room_ids" => "room-a"}),
        cancel_rooms_op(%{"operation_id" => "op-5"}) |> Map.delete("room_ids"),
        cancel_rooms_op(%{"operation_id" => "op-6", "room_ids" => ["room-a", 42]})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_open | results]} = json_response(conn, 200)
      assert Enum.map(results, & &1["code"]) == List.duplicate("invalid_rooms", 6)
      assert Enum.all?(results, &(&1["status"] == "rejected"))

      group = get_group("group-81")
      assert group["revision"] == 1
      assert Enum.all?(group["rooms"], &(&1["status"] == "active"))
    end

    test "rejects a room that was already cancelled", %{conn: conn} do
      operations = [
        open_op(),
        cancel_rooms_op(%{"operation_id" => "op-1"}),
        cancel_rooms_op(%{"operation_id" => "op-2"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, first, second]} = json_response(conn, 200)
      assert first["status"] == "applied"
      assert second["code"] == "invalid_rooms"
    end

    test "rejects missing and inactive groups", %{conn: conn} do
      conn =
        post_batch(conn, %{
          "operations" => [
            cancel_rooms_op(%{"group_id" => "group-missing", "operation_id" => "op-1"})
          ]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "group_not_found"

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            open_op(),
            %{
              "operation_id" => "op-cancel-all",
              "type" => "cancel_group",
              "occurred_on" => "2026-11-20",
              "group_id" => "group-81"
            },
            cancel_rooms_op(%{"operation_id" => "op-after"})
          ]
        })

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["code"] == "group_not_active"
    end

    test "checks the revision before validating rooms", %{conn: conn} do
      operations = [
        open_op(),
        cancel_rooms_op(%{"expected_revision" => 7, "room_ids" => ["room-zz"]})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["code"] == "stale_revision"
      assert result["expected_revision"] == 7
      assert result["actual_revision"] == 1
    end

    test "is durably idempotent", %{conn: conn} do
      operations = [open_op(), payment_op(%{"amount_cents" => 19_500}), cancel_rooms_op()]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      conn = post_batch(build_conn(), %{"operations" => [cancel_rooms_op()]})
      assert %{"results" => [retry]} = json_response(conn, 200)
      assert retry == result

      # the retry did not settle twice
      assert %{"cash_refunded_cents" => 10_500} = get_ledger()
      assert get_group("group-81")["revision"] == 3
    end
  end
end
