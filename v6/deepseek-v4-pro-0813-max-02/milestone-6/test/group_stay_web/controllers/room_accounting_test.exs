defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  defp post_ops(ops) do
    api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => ops})
  end

  defp get_group(group_id) do
    {body, 200} = api_get(build_conn(), "/api/v1/groups/#{group_id}")
    body["data"]
  end

  defp get_ledger(query \\ "") do
    api_get(build_conn(), "/api/v1/ledger#{query}")
  end

  defp result(body, index \\ 0) do
    Enum.at(body["results"], index)
  end

  describe "room-level funding" do
    test "rooms expose status and deposit amounts while totals describe active rooms" do
      {_, 200} = post_ops([open_group_op()])

      group = get_group("group-81")

      assert Enum.map(group["rooms"], & &1["room_id"]) == ["room-a", "room-b"]

      assert group["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "status" => "active",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]

      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 19_500
    end

    test "cash fills rooms in their original order" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      group = get_group("group-81")

      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [5_000, 0]
      assert group["cash_paid_cents"] == 5_000
      assert group["outstanding_deposit_cents"] == 14_500

      {_, 200} =
        post_ops([cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 4_000})])

      group = get_group("group-81")

      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [9_000, 0]
      assert group["cash_paid_cents"] == 9_000

      {_, 200} =
        post_ops([
          cash_payment_op(%{"operation_id" => "op-2003", "amount_cents" => 10_500})
        ])

      group = get_group("group-81")

      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [9_000, 10_500]
      assert group["deposit_paid_cents"] == 19_500
      assert group["outstanding_deposit_cents"] == 0

      {body, 200} =
        post_ops([
          cash_payment_op(%{"operation_id" => "op-2004", "amount_cents" => 1})
        ])

      assert result(body)["code"] == "payment_exceeds_outstanding"
    end

    test "hotel credit fills rooms in their original order" do
      issue = fn group_id ->
        open =
          open_group_op(%{
            "group_id" => "group-cred-#{group_id}",
            "operation_id" => "oc-#{group_id}",
            "occurred_on" => "2026-04-01",
            "arrival_on" => "2026-09-01",
            "departure_on" => "2026-09-04",
            "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 12_500}]
          })

        payment =
          cash_payment_op(%{
            "group_id" => "group-cred-#{group_id}",
            "operation_id" => "pc-#{group_id}",
            "amount_cents" => 5_000
          })

        cancellation =
          cancel_op(%{
            "group_id" => "group-cred-#{group_id}",
            "operation_id" => "cc-#{group_id}",
            "occurred_on" => "2026-04-02",
            "refund_method" => "hotel_credit"
          })

        {_, 200} = post_ops([open, payment, cancellation])
      end

      issue.(1)
      issue.(2)

      {_, 200} = post_ops([open_group_op()])

      {_, 200} =
        post_ops([
          cash_payment_op(%{"amount_cents" => 9_000}),
          apply_hotel_credit_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 10_500})
        ])

      group = get_group("group-81")

      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [9_000, 0]
      assert Enum.map(group["rooms"], & &1["credit_paid_cents"]) == [0, 10_500]
      assert group["cash_paid_cents"] == 9_000
      assert group["credit_paid_cents"] == 10_500
      assert group["deposit_paid_cents"] == 19_500
      assert group["outstanding_deposit_cents"] == 0
    end
  end

  describe "cancel_rooms" do
    setup do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 10_000})])
      :ok
    end

    test "settles the selected room and keeps the rest of the group active" do
      {body, 200} =
        post_ops([cancel_rooms_op(%{"room_ids" => ["room-b"], "expected_revision" => 2})])

      assert result(body) == %{
               "operation_id" => "op-6001",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 1_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      group = get_group("group-81")

      assert group["status"] == "active"
      assert group["lodging_total_cents"] == 45_000
      assert group["deposit_due_cents"] == 9_000
      assert group["deposit_paid_cents"] == 9_000
      assert group["cash_paid_cents"] == 9_000
      assert group["credit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0

      assert group["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 9_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "status" => "cancelled",
                 "deposit_due_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]
    end

    test "returns cancelled room ids in the group's original room order" do
      {body, 200} =
        post_ops([
          cancel_rooms_op(%{"room_ids" => ["room-b", "room-a"]})
        ])

      assert result(body)["cancelled_room_ids"] == ["room-a", "room-b"]
      assert result(body)["refunded_cents"] == 10_000
      assert get_group("group-81")["status"] == "cancelled"
    end

    test "computes one hotel-credit bonus over the selected rooms' combined cash" do
      {body, 200} =
        post_ops([
          cancel_rooms_op(%{
            "room_ids" => ["room-b", "room-a"],
            "refund_method" => "hotel_credit"
          })
        ])

      assert result(body)["refunded_cents"] == 0
      assert result(body)["retained_cents"] == 0
      assert result(body)["credit_issued_cents"] == 11_000

      {credit, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert credit["data"]["available_cents"] == 11_000

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 0
      assert ledger["data"]["cash_converted_to_credit_cents"] == 10_000
      assert ledger["data"]["credit_liability_cents"] == 11_000
    end

    test "settling rooms with different dates retains non-refundable cash" do
      {body, 200} =
        post_ops([cancel_rooms_op(%{"occurred_on" => "2026-11-27"})])

      assert result(body)["refunded_cents"] == 0
      assert result(body)["retained_cents"] == 1_000
      assert get_group("group-81")["status"] == "active"

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_retained_cents"] == 1_000
      assert ledger["data"]["cash_held_cents"] == 9_000
    end

    test "cancel_group later settles only the remaining active rooms" do
      {_, 200} = post_ops([cancel_rooms_op(%{"room_ids" => ["room-b"]})])

      {body, 200} = post_ops([cancel_op(%{"operation_id" => "op-4001"})])

      assert result(body) == %{
               "operation_id" => "op-4001",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 9_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      group = get_group("group-81")
      assert group["status"] == "cancelled"
      assert group["refundable_until"] == "2026-11-26"

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 0
      assert ledger["data"]["cash_refunded_cents"] == 10_000
    end

    test "restores the settled rooms' credit to its original lots" do
      open =
        open_group_op(%{
          "group_id" => "group-91",
          "operation_id" => "op-9001",
          "occurred_on" => "2026-01-05",
          "arrival_on" => "2026-06-01",
          "departure_on" => "2026-06-04",
          "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 12_500}]
        })

      payment =
        cash_payment_op(%{
          "group_id" => "group-91",
          "operation_id" => "op-9002",
          "amount_cents" => 5_000
        })

      cancellation =
        cancel_op(%{
          "group_id" => "group-91",
          "operation_id" => "op-9101",
          "occurred_on" => "2026-04-01",
          "refund_method" => "hotel_credit"
        })

      {_, 200} = post_ops([open, payment, cancellation])

      # The group was already funded by the shared setup: room-a holds
      # 9,000 in cash and room-b holds 1,000 in cash. Apply the guest's
      # whole 5,500-cent lot, which funds room-b (9,500 outstanding).
      {_, 200} =
        post_ops([
          apply_hotel_credit_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 5_500})
        ])

      {body, 200} =
        post_ops([cancel_rooms_op(%{"room_ids" => ["room-b"], "occurred_on" => "2026-11-26"})])

      assert result(body) == %{
               "operation_id" => "op-6001",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 1_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      {credit, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit")

      assert credit["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 5_500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-9101",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-04-01"
                 }
               ]
             }
    end

    test "consumes the settled rooms' credit on non-refundable settlement" do
      open =
        open_group_op(%{
          "group_id" => "group-91",
          "operation_id" => "op-9001",
          "occurred_on" => "2026-01-05",
          "arrival_on" => "2026-06-01",
          "departure_on" => "2026-06-04",
          "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 12_500}]
        })

      payment =
        cash_payment_op(%{
          "group_id" => "group-91",
          "operation_id" => "op-9002",
          "amount_cents" => 5_000
        })

      cancellation =
        cancel_op(%{
          "group_id" => "group-91",
          "operation_id" => "op-9101",
          "occurred_on" => "2026-04-01",
          "refund_method" => "hotel_credit"
        })

      {_, 200} = post_ops([open, payment, cancellation])

      {_, 200} =
        post_ops([
          apply_hotel_credit_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 5_500})
        ])

      {body, 200} =
        post_ops([cancel_rooms_op(%{"operation_id" => "op-6002", "occurred_on" => "2026-11-27"})])

      assert result(body)["refunded_cents"] == 0
      assert result(body)["retained_cents"] == 1_000

      {credit, 200} = api_get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert credit["data"]["available_cents"] == 0

      {ledger, 200} = get_ledger()
      assert ledger["data"]["credit_liability_cents"] == 0
      assert ledger["data"]["cash_retained_cents"] == 1_000
    end

    test "rejects unusable room selectors with invalid_rooms" do
      for {room_ids, index} <-
            Enum.with_index([
              ["room-missing"],
              ["room-a", "room-b", "room-a"],
              [],
              "room-b"
            ]) do
        {body, 200} =
          post_ops([
            cancel_rooms_op(%{"operation_id" => "op-cr#{index}", "room_ids" => room_ids})
          ])

        assert result(body) == %{
                 "operation_id" => "op-cr#{index}",
                 "status" => "rejected",
                 "code" => "invalid_rooms"
               }
      end

      assert get_group("group-81")["revision"] == 2
    end

    test "rejects already cancelled rooms with invalid_rooms" do
      {_, 200} = post_ops([cancel_rooms_op(%{"room_ids" => ["room-b"]})])

      {body, 200} =
        post_ops([cancel_rooms_op(%{"operation_id" => "op-6002", "room_ids" => ["room-b"]})])

      assert result(body)["code"] == "invalid_rooms"
      assert get_group("group-81")["revision"] == 3
    end

    test "rejects a stale revision before room validation" do
      {body, 200} =
        post_ops([
          cancel_rooms_op(%{"room_ids" => ["room-missing"], "expected_revision" => 9})
        ])

      assert result(body) == %{
               "operation_id" => "op-6001",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 2
             }
    end

    test "rejects hotel credit for non-refundable settlements" do
      {body, 200} =
        post_ops([
          cancel_rooms_op(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
        ])

      assert result(body)["code"] == "refund_method_not_available"
      assert get_group("group-81")["status"] == "active"
      assert get_group("group-81")["revision"] == 2
    end

    test "an equivalent retry returns the exact original result without side effects" do
      {body, 200} =
        post_ops([
          cancel_rooms_op(%{"room_ids" => ["room-b"], "refund_method" => "cash"})
        ])

      applied = result(body)

      {retry_body, 200} =
        api_post(build_conn(), "/api/v1/partner-batches", %{
          "operations" => [
            %{
              "room_ids" => ["room-b"],
              "operation_id" => "op-6001",
              "refund_method" => "cash",
              "group_id" => "group-81",
              "type" => "cancel_rooms",
              "occurred_on" => "2026-11-26"
            }
          ]
        })

      assert result(retry_body) == applied
      assert get_group("group-81")["revision"] == 3
    end
  end
end
