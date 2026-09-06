defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  ## helpers

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

  defp payment_op(overrides \\ %{}) do
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

  defp reschedule_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20"
      },
      overrides
    )
  end

  defp cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp credit_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-21",
        "group_id" => "group-82",
        "amount_cents" => 5_000
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
  # hotel credit lot. Returns the cancellation result. `open_overrides` adjust
  # the stay so the cancellation is refundable.
  defp issue_credit(
         conn,
         guest_id,
         group_id,
         cash_cents,
         cancel_overrides \\ %{},
         open_overrides \\ %{}
       ) do
    operations = [
      open_op(
        Map.merge(
          %{
            "operation_id" => "op-open-#{group_id}",
            "group_id" => group_id,
            "guest_id" => guest_id
          },
          open_overrides
        )
      ),
      payment_op(%{
        "operation_id" => "op-pay-#{group_id}",
        "group_id" => group_id,
        "amount_cents" => cash_cents
      }),
      cancel_op(
        Map.merge(
          %{
            "operation_id" => "op-cancel-#{group_id}",
            "group_id" => group_id,
            "refund_method" => "hotel_credit"
          },
          cancel_overrides
        )
      )
    ]

    conn = post_batch(conn, %{"operations" => operations})
    %{"results" => [_, _, result]} = json_response(conn, 200)
    result
  end

  ## batch envelope

  describe "batch envelope" do
    test "missing operations array is an invalid batch", %{conn: conn} do
      conn = post_batch(conn, %{})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "non-list operations is an invalid batch", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => %{"operation_id" => "op-1"}})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "unknown operation type is rejected with invalid_operation", %{conn: conn} do
      conn =
        post_batch(conn, %{"operations" => [%{"operation_id" => "op-1", "type" => "hold_room"}]})

      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-1",
               "status" => "rejected",
               "code" => "invalid_operation"
             }
    end

    test "operation missing identifying fields is rejected with invalid_operation", %{conn: conn} do
      operations = [
        Map.delete(open_op(), "group_id"),
        Map.delete(open_op(), "guest_id"),
        Map.delete(payment_op(), "group_id"),
        Map.delete(cancel_op(), "occurred_on"),
        Map.delete(open_op(), "operation_id")
      ]

      conn = post_batch(conn, %{"operations" => operations})
      %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, & &1["status"]) == ~w(rejected rejected rejected rejected rejected)
      assert Enum.map(results, & &1["code"]) == List.duplicate("invalid_operation", 5)
    end

    test "results are returned in operation order and a rejection does not stop the batch",
         %{conn: conn} do
      operations = [
        open_op(%{"operation_id" => "op-1"}),
        payment_op(%{"operation_id" => "op-2", "group_id" => "group-missing"}),
        open_op(%{
          "operation_id" => "op-3",
          "group_id" => "group-82",
          "rate_plan" => "advance_purchase"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)

      assert [first, second, third] = results
      assert first["operation_id"] == "op-1"
      assert first["status"] == "applied"
      assert second["operation_id"] == "op-2"
      assert second["status"] == "rejected"
      assert second["code"] == "group_not_found"
      assert third["operation_id"] == "op-3"
      assert third["status"] == "applied"
    end

    test "an operation observes changes made by an earlier operation in the same batch",
         %{conn: conn} do
      operations = [
        open_op(%{"operation_id" => "op-1"}),
        payment_op(%{"operation_id" => "op-2", "amount_cents" => 19_500})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, payment]} = json_response(conn, 200)
      assert payment["status"] == "applied"
      assert payment["outstanding_deposit_cents"] == 0
      assert payment["revision"] == 2
    end
  end

  ## open_group

  describe "open_group" do
    test "applies the API document example", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [open_op()]})

      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
    end

    test "rounds each room's flexible deposit separately, half-cents up", %{conn: conn} do
      # two nights: room-a lodging 3002 -> deposit 600.4 -> 600; room-b lodging 3003 -> 600.6 -> 601
      conn =
        post_batch(conn, %{
          "operations" => [
            open_op(%{
              "departure_on" => "2026-12-12",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 1501},
                %{"room_id" => "room-b", "nightly_rate_cents" => 1501.5 + 0.5}
              ]
            })
          ]
        })

      %{"results" => [first]} = json_response(conn, 200)
      # second room is fractional and must be rejected
      assert first["code"] == "invalid_rooms"

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            open_op(%{
              "departure_on" => "2026-12-12",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 1501},
                %{"room_id" => "room-b", "nightly_rate_cents" => 1502}
              ]
            })
          ]
        })

      %{"results" => [result]} = json_response(conn, 200)
      # room-a: 2 * 1501 = 3002 lodging, 20% = 600.4 -> 600
      # room-b: 2 * 1502 = 3004 lodging, 20% = 600.8 -> 601
      assert result["status"] == "applied"
      assert result["deposit_due_cents"] == 1201
    end

    test "advance purchase requires the full lodging amount", %{conn: conn} do
      conn =
        post_batch(conn, %{
          "operations" => [open_op(%{"rate_plan" => "advance_purchase"})]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      # full lodging: 3 * 15000 + 3 * 17500
      assert result["deposit_due_cents"] == 97_500
    end

    test "rejects an existing group identifier", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [open_op()]})
      conn = post_batch(conn, %{"operations" => [open_op(%{"operation_id" => "op-again"})]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "rejected"
      assert result["code"] == "group_already_exists"

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => group} = json_response(conn, 200)
      assert group["revision"] == 1
    end

    test "rejects stays without a night", %{conn: conn} do
      operations = [
        open_op(%{"departure_on" => "2026-12-10", "operation_id" => "op-1"}),
        open_op(%{
          "arrival_on" => "2026-12-13",
          "departure_on" => "2026-12-10",
          "operation_id" => "op-2"
        }),
        open_op(%{"departure_on" => "not-a-date", "operation_id" => "op-3"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.map(results, & &1["code"]) == ~w(invalid_stay invalid_stay invalid_stay)
    end

    test "rejects unusable room lists", %{conn: conn} do
      operations = [
        open_op(%{"rooms" => [], "operation_id" => "op-1"}),
        open_op(%{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 150},
            %{"room_id" => "room-a", "nightly_rate_cents" => 200}
          ],
          "operation_id" => "op-2"
        }),
        open_op(%{"rooms" => [%{"room_id" => "room-a"}], "operation_id" => "op-3"}),
        open_op(%{
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -1}],
          "operation_id" => "op-4"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.map(results, & &1["code"]) == List.duplicate("invalid_rooms", 4)
    end

    test "rejects unknown rate plans", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [open_op(%{"rate_plan" => "weekend"})]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "invalid_rate_plan"
    end

    test "ignored expected_revision and books the group on occurred_on", %{conn: conn} do
      conn =
        post_batch(conn, %{
          "operations" => [open_op(%{"expected_revision" => 7})]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["revision"] == 1

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => group} = json_response(conn, 200)
      assert group["booked_on"] == "2026-10-03"
    end
  end

  ## record_cash_payment

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 19_500})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 19_500,
               "outstanding_deposit_cents" => 0,
               "revision" => 2
             }
    end

    test "rejects missing groups", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [payment_op()]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "group_not_found"
    end

    test "rejects unusable amounts", %{conn: conn} do
      operations = [
        payment_op(%{"amount_cents" => 0, "operation_id" => "op-1"}),
        payment_op(%{"amount_cents" => -100, "operation_id" => "op-2"}),
        payment_op(%{"amount_cents" => "5000", "operation_id" => "op-3"}),
        Map.delete(payment_op(), "amount_cents") |> Map.put("operation_id", "op-4")
      ]

      conn =
        post_batch(conn, %{
          "operations" => [open_op(%{"operation_id" => "op-open"}) | operations]
        })

      assert %{"results" => [_open | results]} = json_response(conn, 200)
      assert Enum.map(results, & &1["code"]) == List.duplicate("invalid_amount", 4)

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => group} = json_response(conn, 200)
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0
    end

    test "rejects payments above the outstanding deposit", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 19_501})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["code"] == "payment_exceeds_outstanding"
    end
  end

  ## reschedule_group

  describe "reschedule_group" do
    test "shifts the stay without changing its length or price", %{conn: conn} do
      operations = [
        open_op(),
        reschedule_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 2
             }
    end

    test "allows moving the stay earlier when it stays after the operation date",
         %{conn: conn} do
      operations = [
        open_op(),
        reschedule_op(%{"new_arrival_on" => "2026-12-01"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["new_arrival_on"] == "2026-12-01"
      assert result["new_departure_on"] == "2026-12-04"
    end

    test "rejects unusable dates", %{conn: conn} do
      operations = [
        open_op(),
        # equal to the operation date is not after it
        reschedule_op(%{"new_arrival_on" => "2026-10-05", "operation_id" => "op-1"}),
        # before the operation date
        reschedule_op(%{"new_arrival_on" => "2026-10-01", "operation_id" => "op-2"}),
        # not a date
        reschedule_op(%{"new_arrival_on" => "later", "operation_id" => "op-3"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_open | results]} = json_response(conn, 200)
      assert Enum.map(results, & &1["code"]) == ~w(invalid_stay invalid_stay invalid_stay)
    end

    test "rejects missing groups", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [reschedule_op()]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "group_not_found"
    end
  end

  ## cancel_group

  describe "cancel_group" do
    test "refunds cash for flexible groups cancelled at least 14 days before arrival",
         %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
    end

    test "retains cash for flexible groups cancelled inside the notice window",
         %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        # 13 days before arrival 2026-12-10
        cancel_op(%{"occurred_on" => "2026-11-27"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 10_000
    end

    test "always retains cash for advance purchase groups", %{conn: conn} do
      operations = [
        open_op(%{"rate_plan" => "advance_purchase"}),
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 10_000
    end

    test "forgives the unpaid remainder and blocks later operations", %{conn: conn} do
      operations = [
        open_op(),
        cancel_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      later = [
        payment_op(%{"operation_id" => "op-after-pay"}),
        reschedule_op(%{"operation_id" => "op-after-move"}),
        cancel_op(%{"operation_id" => "op-after-cancel"})
      ]

      conn = post_batch(build_conn(), %{"operations" => later})

      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, & &1["code"]) ==
               ~w(group_not_active group_not_active group_not_active)

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => group} = json_response(conn, 200)
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
      # rejected operations do not move the revision
      assert group["revision"] == 2
    end

    test "rejects missing groups", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [cancel_op()]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "group_not_found"
    end
  end

  ## concurrent updates

  describe "revisions" do
    test "each applied operation increments the revision exactly once", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 5_000}),
        reschedule_op(),
        payment_op(%{"amount_cents" => 1_000, "operation_id" => "op-second-pay"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4]
    end

    test "applies when expected_revision matches", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"expected_revision" => 1, "amount_cents" => 5_000}),
        payment_op(%{
          "expected_revision" => 2,
          "amount_cents" => 1_000,
          "operation_id" => "op-more"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, first, second]} = json_response(conn, 200)
      assert first["status"] == "applied"
      assert first["revision"] == 2
      assert second["status"] == "applied"
      assert second["revision"] == 3
    end

    test "rejects a stale revision before other validation and reports both revisions",
         %{conn: conn} do
      operations = [
        open_op(),
        # stale but otherwise valid
        payment_op(%{"expected_revision" => 4, "operation_id" => "op-1"}),
        # stale and also above the outstanding deposit: the revision must win
        payment_op(%{
          "expected_revision" => 3,
          "amount_cents" => 1_000_000,
          "operation_id" => "op-2"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, first, second]} = json_response(conn, 200)

      assert first == %{
               "operation_id" => "op-1",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 4,
               "actual_revision" => 1
             }

      assert second["code"] == "stale_revision"
      assert second["expected_revision"] == 3
      assert second["actual_revision"] == 1

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => group} = json_response(conn, 200)
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0
    end

    test "group existence is resolved before revisions are compared", %{conn: conn} do
      conn =
        post_batch(conn, %{
          "operations" => [payment_op(%{"expected_revision" => 9, "group_id" => "group-other"})]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "group_not_found"
    end

    test "expected revision still applies to a cancelled group", %{conn: conn} do
      operations = [
        open_op(),
        cancel_op(),
        payment_op(%{
          "expected_revision" => 1,
          "amount_cents" => 100,
          "operation_id" => "op-stale"
        }),
        payment_op(%{
          "expected_revision" => 2,
          "amount_cents" => 100,
          "operation_id" => "op-fresh"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, stale, fresh]} = json_response(conn, 200)
      assert stale["code"] == "stale_revision"
      assert fresh["code"] == "group_not_active"
    end
  end

  ## policy versions

  describe "policy versions" do
    test "flexible groups booked before 2027-01-01 keep the 14-day window", %{conn: conn} do
      conn =
        post_batch(conn, %{
          "operations" => [
            open_op(%{
              "occurred_on" => "2026-12-31",
              "arrival_on" => "2027-02-01",
              "departure_on" => "2027-02-03"
            })
          ]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "applied"

      group = get_group("group-81")
      assert group["booked_on"] == "2026-12-31"
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-01-18"
    end

    test "flexible groups booked on or after 2027-01-01 use the 30-day window", %{conn: conn} do
      for booked_on <- ["2027-01-01", "2027-06-15"] do
        group_id = "group-#{booked_on}"

        conn =
          post_batch(conn, %{
            "operations" => [
              open_op(%{
                "group_id" => group_id,
                "occurred_on" => booked_on,
                "arrival_on" => "2027-08-01",
                "departure_on" => "2027-08-03"
              })
            ]
          })

        assert %{"results" => [result]} = json_response(conn, 200)
        assert result["status"] == "applied"

        group = get_group(group_id)
        assert group["policy_version"] == "flex-30"
        assert group["refundable_until"] == "2027-07-02"
      end
    end

    test "advance purchase groups are never refundable", %{conn: conn} do
      conn =
        post_batch(conn, %{"operations" => [open_op(%{"rate_plan" => "advance_purchase"})]})

      assert %{"results" => [_]} = json_response(conn, 200)

      group = get_group("group-81")
      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "cancelling on refundable_until is refundable under both windows", %{conn: conn} do
      operations = [
        # flex-14: arrival 2026-12-10, refundable_until 2026-11-26
        open_op(%{"group_id" => "group-14", "operation_id" => "op-open-14"}),
        payment_op(%{
          "group_id" => "group-14",
          "amount_cents" => 1_000,
          "operation_id" => "p-14"
        }),
        cancel_op(%{
          "group_id" => "group-14",
          "occurred_on" => "2026-11-26",
          "operation_id" => "c-14"
        }),
        # flex-30: arrival 2027-06-01, refundable_until 2027-05-02
        open_op(%{
          "group_id" => "group-30",
          "occurred_on" => "2027-01-05",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04",
          "operation_id" => "op-open-30"
        }),
        payment_op(%{
          "group_id" => "group-30",
          "amount_cents" => 1_000,
          "operation_id" => "p-30"
        }),
        cancel_op(%{
          "group_id" => "group-30",
          "occurred_on" => "2027-05-02",
          "operation_id" => "c-30"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)

      assert [%{"refunded_cents" => 1_000}, %{"refunded_cents" => 1_000}] =
               Enum.map([Enum.at(results, 2), Enum.at(results, 5)], & &1)
    end

    test "cancelling one day past refundable_until is retained under both windows", %{conn: conn} do
      operations = [
        open_op(%{"group_id" => "group-14", "operation_id" => "op-open-14"}),
        payment_op(%{
          "group_id" => "group-14",
          "amount_cents" => 1_000,
          "operation_id" => "p-14"
        }),
        cancel_op(%{
          "group_id" => "group-14",
          "occurred_on" => "2026-11-27",
          "operation_id" => "c-14"
        }),
        open_op(%{
          "group_id" => "group-30",
          "occurred_on" => "2027-01-05",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04",
          "operation_id" => "op-open-30"
        }),
        payment_op(%{
          "group_id" => "group-30",
          "amount_cents" => 1_000,
          "operation_id" => "p-30"
        }),
        cancel_op(%{
          "group_id" => "group-30",
          "occurred_on" => "2027-05-03",
          "operation_id" => "c-30"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)

      for index <- [2, 5] do
        result = Enum.at(results, index)
        assert result["status"] == "applied"
        assert result["refunded_cents"] == 0
        assert result["retained_cents"] == 1_000
      end
    end

    test "rescheduling keeps the fixed policy and recomputes refundable_until", %{conn: conn} do
      operations = [
        # booked in 2026, so the 14-day window is fixed even when the stay
        # moves past the policy cut-over
        open_op(%{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-02-01",
          "departure_on" => "2027-02-03"
        }),
        reschedule_op(%{"new_arrival_on" => "2027-03-01", "occurred_on" => "2027-01-10"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2027-03-01",
               "new_departure_on" => "2027-03-03",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-02-15",
               "revision" => 2
             }

      group = get_group("group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-02-15"
    end

    test "rescheduling an advance purchase group reports a null refundable_until", %{conn: conn} do
      operations = [
        open_op(%{"rate_plan" => "advance_purchase"}),
        reschedule_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["policy_version"] == "advance-nonrefundable"
      assert result["refundable_until"] == nil
    end
  end

  ## issuing credit on cancellation

  describe "cancel_group with hotel_credit" do
    test "converts the cash into a credit lot with the 10% bonus", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op(%{"refund_method" => "hotel_credit"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_000,
               "revision" => 3
             }

      group = get_group("group-81")
      assert group["status"] == "cancelled"

      ledger = get_ledger()

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 11_000
             } = ledger

      credit = get_credit("guest-22")

      assert credit == %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 11_000,
                   # 365 days after the 2026-11-20 cancellation
                   "expires_on" => "2027-11-20"
                 }
               ]
             }
    end

    test "rounds the 10% bonus half-cents upward", %{conn: conn} do
      result = issue_credit(conn, "guest-22", "group-81", 10_005)

      # 10_005 cash + round(10_005 * 0.10 = 1000.5) = 10_005 + 1_001
      assert result["status"] == "applied"
      assert result["credit_issued_cents"] == 11_006
    end

    test "rejects hotel credit for a non-refundable cancellation and leaves the group active",
         %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        # 13 days before arrival: inside the flex-14 window
        cancel_op(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"

      group = get_group("group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2

      assert %{"cash_held_cents" => 10_000, "cash_converted_to_credit_cents" => 0} = get_ledger()
      assert get_credit("guest-22")["available_cents"] == 0
    end

    test "rejects hotel credit for advance purchase cancellations", %{conn: conn} do
      operations = [
        open_op(%{"rate_plan" => "advance_purchase"}),
        payment_op(%{"amount_cents" => 10_000}),
        # far enough out that a flexible group would be refundable
        cancel_op(%{"occurred_on" => "2026-10-10", "refund_method" => "hotel_credit"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["code"] == "refund_method_not_available"

      group = get_group("group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2
    end

    test "a stale revision is reported before the refund method is considered", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op(%{
          "occurred_on" => "2026-11-27",
          "refund_method" => "hotel_credit",
          "expected_revision" => 1
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)
      assert result["code"] == "stale_revision"
      assert result["expected_revision"] == 1
      assert result["actual_revision"] == 2
    end

    test "rejects an unusable refund method without changing the group", %{conn: conn} do
      conn =
        post_batch(conn, %{
          "operations" => [
            open_op(),
            cancel_op(%{"refund_method" => "voucher"})
          ]
        })

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["code"] == "invalid_operation"

      group = get_group("group-81")
      assert group["status"] == "active"
      assert group["revision"] == 1
    end

    test "issues no credit when a refundable group holds no cash", %{conn: conn} do
      conn =
        post_batch(conn, %{
          "operations" => [open_op(), cancel_op(%{"refund_method" => "hotel_credit"})]
        })

      assert %{"results" => [_, result]} = json_response(conn, 200)

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert get_credit("guest-22")["available_cents"] == 0

      assert %{"cash_converted_to_credit_cents" => 0, "credit_liability_cents" => 0} =
               get_ledger()
    end
  end

  ## applying credit

  describe "apply_hotel_credit" do
    test "redeems credit into the outstanding deposit", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      operations = [
        open_op(%{
          "group_id" => "group-82",
          "occurred_on" => "2026-11-21",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-03",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}],
          "operation_id" => "op-open-82"
        }),
        credit_op(%{"amount_cents" => 5_000, "occurred_on" => "2026-11-22"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-credit",
               "status" => "applied",
               "group_id" => "group-82",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 3_000,
               "revision" => 2
             }

      group = get_group("group-82")

      assert %{
               "deposit_paid_cents" => 5_000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 5_000,
               "outstanding_deposit_cents" => 3_000
             } = group

      # applying credit moves it inside the deposit but does not change the
      # liability, and it never counts as cash
      assert %{"cash_held_cents" => 0, "credit_liability_cents" => 11_000} = get_ledger()

      credit = get_credit("guest-22")

      assert %{
               "available_cents" => 6_000,
               "lots" => [
                 %{"source_operation_id" => "op-cancel-group-81", "remaining_cents" => 6_000}
               ]
             } = credit
    end

    test "rejects when the guest cannot cover the amount", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      operations = [
        open_op(%{"group_id" => "group-82", "operation_id" => "op-open-82"}),
        credit_op(%{"amount_cents" => 11_001})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"

      group = get_group("group-82")
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0

      # the failed attempt consumed nothing
      assert get_credit("guest-22")["available_cents"] == 11_000
      assert %{"credit_liability_cents" => 11_000} = get_ledger()
    end

    test "rejects credit for a group of a different guest", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            open_op(%{
              "group_id" => "group-82",
              "guest_id" => "guest-other",
              "operation_id" => "op-open-82"
            }),
            credit_op()
          ]
        })

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["code"] == "insufficient_credit"
    end

    test "rejects credit above the outstanding deposit even with enough credit", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 18_000)

      # the guest holds 19_800 of credit but group-82 owes only 19_500
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            open_op(%{"group_id" => "group-82", "operation_id" => "op-open-82"}),
            credit_op(%{"amount_cents" => 19_501})
          ]
        })

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["code"] == "payment_exceeds_outstanding"
    end

    test "rejects unusable amounts", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            open_op(%{"group_id" => "group-82", "operation_id" => "op-open-82"}),
            credit_op(%{"amount_cents" => 0, "operation_id" => "op-1"}),
            credit_op(%{"amount_cents" => -100, "operation_id" => "op-2"}),
            credit_op(%{"amount_cents" => "5000", "operation_id" => "op-3"})
          ]
        })

      assert %{"results" => [_ | results]} = json_response(conn, 200)
      assert Enum.map(results, & &1["code"]) == ~w(invalid_amount invalid_amount invalid_amount)
    end

    test "rejects missing and inactive groups", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            credit_op(%{"group_id" => "group-missing", "operation_id" => "op-1"}),
            credit_op(%{"group_id" => "group-81", "operation_id" => "op-2"})
          ]
        })

      assert %{"results" => [missing, cancelled]} = json_response(conn, 200)
      assert missing["code"] == "group_not_found"
      assert cancelled["code"] == "group_not_active"
    end

    test "evaluates expiry using the operation date", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      # the lot expires on 2027-11-20; an operation on that day can still use it
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            open_op(%{"group_id" => "group-82", "operation_id" => "op-open-82"}),
            credit_op(%{"amount_cents" => 1_000, "occurred_on" => "2027-11-20"})
          ]
        })

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["status"] == "applied"

      # one day later the credit is gone
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            credit_op(%{
              "amount_cents" => 1_000,
              "occurred_on" => "2027-11-21",
              "operation_id" => "op-late"
            })
          ]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "insufficient_credit"
    end

    test "follows the revision contract", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      operations = [
        open_op(%{"group_id" => "group-82", "operation_id" => "op-open-82"}),
        credit_op(%{"expected_revision" => 1, "amount_cents" => 1_000, "operation_id" => "op-1"}),
        credit_op(%{"expected_revision" => 1, "amount_cents" => 1_000, "operation_id" => "op-2"}),
        credit_op(%{"expected_revision" => 2, "amount_cents" => 12_000, "operation_id" => "op-3"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})

      assert %{"results" => [_, applied, stale, fresh]} = json_response(conn, 200)
      assert applied["status"] == "applied"
      assert applied["revision"] == 2
      assert stale["code"] == "stale_revision"
      # a rejected insufficient-credit attempt does not advance the revision
      assert fresh["code"] == "insufficient_credit"

      assert get_group("group-82")["revision"] == 2
    end

    test "consumes lots by earliest expiry, then by source operation", %{conn: conn} do
      # lot cancel-b expires 2027-12-01; lot cancel-a expires 2028-01-01
      issue_credit(
        conn,
        "guest-22",
        "group-81",
        1_000,
        %{"operation_id" => "cancel-b", "occurred_on" => "2026-12-01"},
        %{"arrival_on" => "2027-01-15", "departure_on" => "2027-01-16"}
      )

      issue_credit(
        build_conn(),
        "guest-22",
        "group-91",
        1_000,
        %{"operation_id" => "cancel-a", "occurred_on" => "2027-01-01"},
        %{"arrival_on" => "2027-02-01", "departure_on" => "2027-02-02"}
      )

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            open_op(%{
              "group_id" => "group-82",
              "occurred_on" => "2027-06-01",
              "arrival_on" => "2027-09-01",
              "departure_on" => "2027-09-02",
              "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}],
              "operation_id" => "op-open-82"
            }),
            credit_op(%{"amount_cents" => 1_500, "occurred_on" => "2027-06-02"})
          ]
        })

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["status"] == "applied"

      # cancel-b (earlier expiry) is exhausted; 400 came out of cancel-a
      credit = get_credit("guest-22")

      assert credit == %{
               "guest_id" => "guest-22",
               "available_cents" => 700,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-a",
                   "remaining_cents" => 700,
                   "expires_on" => "2028-01-01"
                 }
               ]
             }
    end

    test "breaks expiry ties by source operation", %{conn: conn} do
      for {group_id, cancel_id} <- [{"group-81", "cancel-a"}, {"group-91", "cancel-b"}] do
        issue_credit(
          build_conn(),
          "guest-22",
          group_id,
          1_000,
          %{"operation_id" => cancel_id, "occurred_on" => "2027-01-01"},
          %{"arrival_on" => "2027-02-01", "departure_on" => "2027-02-02"}
        )
      end

      conn =
        post_batch(conn, %{
          "operations" => [
            open_op(%{
              "group_id" => "group-82",
              "occurred_on" => "2027-06-01",
              "arrival_on" => "2027-09-01",
              "departure_on" => "2027-09-02",
              "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}],
              "operation_id" => "op-open-82"
            }),
            credit_op(%{"amount_cents" => 1_100, "occurred_on" => "2027-06-02"})
          ]
        })

      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["status"] == "applied"

      # both lots expire 2028-01-01; cancel-a is consumed first
      assert [%{"source_operation_id" => "cancel-b", "remaining_cents" => 1_100}] =
               get_credit("guest-22")["lots"]
    end
  end

  ## settling a group funded by credit

  describe "settling credit-funded groups" do
    test "a refundable cancellation restores credit to its lot without a second bonus",
         %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      operations = [
        open_op(%{
          "group_id" => "group-82",
          "occurred_on" => "2026-11-21",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-03",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}],
          "operation_id" => "op-open-82"
        }),
        credit_op(%{"amount_cents" => 5_000, "occurred_on" => "2026-11-22"}),
        cancel_op(%{"group_id" => "group-82", "occurred_on" => "2027-01-15"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})

      assert %{"results" => [_, _, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-82",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      # the applied 5_000 returns to the original lot with its original expiry
      credit = get_credit("guest-22")

      assert credit == %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-group-81",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-20"
                 }
               ]
             }

      assert %{"credit_liability_cents" => 11_000} = get_ledger()
    end

    test "restored credit that has already expired reduces the liability instead",
         %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      operations = [
        open_op(%{
          "group_id" => "group-82",
          "occurred_on" => "2027-01-05",
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}],
          "operation_id" => "op-open-82"
        }),
        credit_op(%{"amount_cents" => 3_000, "occurred_on" => "2027-01-10"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      # after the lot's 2027-11-20 expiry only the paused, applied 3_000
      # remains in the liability
      assert %{"credit_liability_cents" => 3_000} = get_ledger("?on=2027-12-01")
      assert get_credit("guest-22", "?on=2027-12-01")["available_cents"] == 0

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            cancel_op(%{
              "group_id" => "group-82",
              "occurred_on" => "2027-12-15",
              "operation_id" => "op-cancel-82"
            })
          ]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "applied"

      # the restored amount expired immediately: no credit comes back
      assert %{"credit_liability_cents" => 0} = get_ledger("?on=2027-12-15")
      assert get_credit("guest-22", "?on=2027-12-15")["available_cents"] == 0
    end

    test "repeated applications accumulate and restore together", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      operations = [
        open_op(%{
          "group_id" => "group-82",
          "occurred_on" => "2026-11-21",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-03",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}],
          "operation_id" => "op-open-82"
        }),
        credit_op(%{
          "amount_cents" => 1_000,
          "occurred_on" => "2026-11-22",
          "operation_id" => "c-1"
        }),
        credit_op(%{
          "amount_cents" => 2_000,
          "occurred_on" => "2026-11-23",
          "operation_id" => "c-2"
        }),
        cancel_op(%{"group_id" => "group-82", "occurred_on" => "2027-01-15"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})

      assert %{"results" => [_, first, second, cancel]} = json_response(conn, 200)
      assert first["revision"] == 2
      assert second["revision"] == 3
      assert second["outstanding_deposit_cents"] == 5_000
      assert cancel["status"] == "applied"

      # both applications return to the original lot
      assert %{"available_cents" => 11_000} = get_credit("guest-22")
    end

    test "a non-refundable cancellation retains cash and consumes applied credit",
         %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      operations = [
        open_op(%{
          "group_id" => "group-82",
          "occurred_on" => "2027-01-05",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-03",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}],
          "operation_id" => "op-open-82"
        }),
        payment_op(%{
          "group_id" => "group-82",
          "amount_cents" => 3_000,
          "occurred_on" => "2027-01-06",
          "operation_id" => "op-pay-82"
        }),
        credit_op(%{"amount_cents" => 2_000, "occurred_on" => "2027-01-10"}),
        # 9 days before arrival: inside the flex-30 window
        cancel_op(%{
          "group_id" => "group-82",
          "occurred_on" => "2027-02-20",
          "operation_id" => "op-cancel-82"
        })
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 3_000
      assert result["credit_issued_cents"] == 0

      # the consumed 2_000 leaves the liability; the untouched 9_000 stays
      assert %{
               "cash_retained_cents" => 3_000,
               "credit_liability_cents" => 9_000
             } = get_ledger()

      assert get_credit("guest-22")["available_cents"] == 9_000
    end

    test "a mixed settlement converts cash with the bonus and restores credit untouched",
         %{conn: conn} do
      issue_credit(conn, "guest-22", "group-81", 10_000)

      operations = [
        open_op(%{
          "group_id" => "group-82",
          "occurred_on" => "2026-11-21",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-03",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}],
          "operation_id" => "op-open-82"
        }),
        payment_op(%{
          "group_id" => "group-82",
          "amount_cents" => 3_000,
          "occurred_on" => "2026-11-22",
          "operation_id" => "op-pay-82"
        }),
        credit_op(%{"amount_cents" => 2_000, "occurred_on" => "2026-11-23"}),
        cancel_op(%{
          "group_id" => "group-82",
          "occurred_on" => "2027-01-15",
          "refund_method" => "hotel_credit",
          "operation_id" => "op-cancel-82"
        })
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 3_300

      credit = get_credit("guest-22")

      assert credit["available_cents"] == 11_000 + 3_300

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-group-81",
                 "remaining_cents" => 11_000,
                 "expires_on" => "2027-11-20"
               },
               %{
                 "source_operation_id" => "op-cancel-82",
                 "remaining_cents" => 3_300,
                 # 365 days after the 2027-01-15 cancellation
                 "expires_on" => "2028-01-15"
               }
             ]

      # converted cash accumulates across both credit settlements
      assert %{
               "cash_held_cents" => 0,
               "cash_converted_to_credit_cents" => 13_000,
               "credit_liability_cents" => 14_300
             } = get_ledger()
    end
  end
end
