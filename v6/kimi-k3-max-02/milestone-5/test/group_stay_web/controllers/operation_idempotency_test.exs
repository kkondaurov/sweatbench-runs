defmodule GroupStayWeb.OperationIdempotencyTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Groups.OperationRecord
  alias GroupStay.Repo

  defp post_batch(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(payload))
  end

  defp post_raw_batch(conn, json) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", json)
  end

  defp submit(conn, operations) do
    conn
    |> post_batch(%{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit_one(conn, operation) do
    [result] = submit(conn, [operation])
    result
  end

  defp open_operation(overrides \\ %{}) do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp payment_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 10000
      },
      overrides
    )
  end

  defp open_group!(conn, overrides \\ %{}) do
    result = submit_one(conn, open_operation(overrides))
    assert result["status"] == "applied"
    result
  end

  defp get_group(conn, group_id) do
    conn |> get(~p"/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_operation(conn, operation_id) do
    get(conn, ~p"/api/v1/operations/#{operation_id}")
  end

  describe "retry behavior" do
    test "an exact retry returns the original result without touching domain state", %{conn: conn} do
      open_group!(conn)

      original = submit_one(conn, payment_operation())

      assert original == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 10000,
               "outstanding_deposit_cents" => 9500,
               "revision" => 2
             }

      # the gateway retries the identical operation in a later batch
      assert submit_one(conn, payment_operation()) == original

      # the payment was applied exactly once
      group = get_group(conn, "group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 10000
      assert group["outstanding_deposit_cents"] == 9500
    end

    test "a retry of open_group returns the original result instead of group_already_exists", %{
      conn: conn
    } do
      original = open_group!(conn)

      assert submit_one(conn, open_operation()) == original

      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "a duplicate inside one batch is answered from the original result", %{conn: conn} do
      results =
        submit(conn, [
          open_operation(),
          payment_operation(),
          payment_operation()
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2} = first_pay,
               second_pay
             ] = results

      assert second_pay == first_pay

      # the payment was applied exactly once
      assert get_group(conn, "group-81")["deposit_paid_cents"] == 10000
    end

    test "object key order is irrelevant to payload equivalence", %{conn: conn} do
      assert %{"results" => [%{"status" => "applied"}]} =
               post_raw_batch(conn, """
               {"operations":[
                 {"operation_id":"op-open","type":"open_group","occurred_on":"2026-10-03",
                  "group_id":"group-81","guest_id":"guest-22","property_id":"ams-canal",
                  "arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible",
                  "rooms":[{"room_id":"room-a","nightly_rate_cents":15000}]}
               ]}
               """)
               |> json_response(200)

      # the same operation with every object's keys in a different order
      assert %{"results" => [retry]} =
               post_raw_batch(conn, """
               {"operations":[
                 {"rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"}],
                  "rate_plan":"flexible","departure_on":"2026-12-13","arrival_on":"2026-12-10",
                  "property_id":"ams-canal","guest_id":"guest-22","group_id":"group-81",
                  "occurred_on":"2026-10-03","type":"open_group","operation_id":"op-open"}
               ]}
               """)
               |> json_response(200)

      assert retry == %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 9000,
               "revision" => 1
             }

      # the group was opened exactly once
      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "array order and values remain significant", %{conn: conn} do
      open_group!(conn)

      # the rooms array in a different order is a different payload
      reordered_rooms =
        open_operation(%{
          "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
          ]
        })

      result = submit_one(conn, reordered_rooms)
      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"

      # a different value is a different payload
      result = submit_one(conn, payment_operation(%{"amount_cents" => 9500}))
      assert result["status"] == "applied"

      conflicted = payment_operation(%{"amount_cents" => 9501})
      result = submit_one(conn, conflicted)
      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"
    end

    test "a rejected operation is remembered and retried verbatim", %{conn: conn} do
      open_group!(conn)

      # no credit available for the guest yet
      apply_operation = %{
        "operation_id" => "op-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "amount_cents" => 5000
      }

      original = submit_one(conn, apply_operation)
      assert original["status"] == "rejected"
      assert original["code"] == "insufficient_credit"

      # the guest earns credit later, so the operation would now succeed
      open_group!(conn, %{"operation_id" => "op-open-82", "group_id" => "group-82"})

      submit_one(conn, %{
        "operation_id" => "op-pay-82",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-82",
        "amount_cents" => 10000
      })

      submit_one(conn, %{
        "operation_id" => "op-cancel-82",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-82",
        "refund_method" => "hotel_credit"
      })

      # the retry still receives the original rejection
      assert submit_one(conn, apply_operation) == original

      group = get_group(conn, "group-81")
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0
    end

    test "an invalid_operation rejection is remembered", %{conn: conn} do
      operation = open_operation(%{"rate_plan" => "bogus"})

      original = submit_one(conn, operation)
      assert original["status"] == "rejected"
      assert original["code"] == "invalid_rate_plan"

      assert submit_one(conn, operation) == original

      # a corrected payload under the same identifier is a conflict
      result = submit_one(conn, open_operation())
      assert result["code"] == "operation_id_conflict"

      # and the group was never created
      assert conn
             |> get(~p"/api/v1/groups/group-81")
             |> json_response(404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "a stale_revision rejection is remembered with its original details", %{conn: conn} do
      open_group!(conn)
      submit_one(conn, payment_operation())

      stale =
        payment_operation(%{
          "operation_id" => "op-stale",
          "amount_cents" => 5000,
          "expected_revision" => 1
        })

      original = submit_one(conn, stale)

      assert original == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      # the group moves on to revision 3
      submit_one(conn, payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 5000}))

      # the exact retry returns the original stale result verbatim, even
      # though the group's actual revision is now 3
      assert submit_one(conn, stale) == original

      # retrying under the same identifier with the corrected expected
      # revision is a different payload and conflicts
      corrected =
        payment_operation(%{
          "operation_id" => "op-stale",
          "amount_cents" => 5000,
          "expected_revision" => 3
        })

      result = submit_one(conn, corrected)
      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"

      assert get_group(conn, "group-81")["revision"] == 3
    end

    test "a conflict does not replace the original record or change domain state", %{conn: conn} do
      open_group!(conn)
      original = submit_one(conn, payment_operation())

      conflict = submit_one(conn, payment_operation(%{"amount_cents" => 5000}))

      assert conflict == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "operation_id_conflict",
               "group_id" => "group-81"
             }

      # the original record still answers exact retries
      assert submit_one(conn, payment_operation()) == original

      # nothing changed
      group = get_group(conn, "group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 10000
    end

    test "a conflicting operation does not stop later operations in the batch", %{conn: conn} do
      results =
        submit(conn, [
          open_operation(),
          open_operation(%{"guest_id" => "guest-99"}),
          payment_operation()
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "rejected", "code" => "operation_id_conflict"},
               %{"status" => "applied", "revision" => 2}
             ] = results
    end

    test "concurrent first attempts apply the operation at most once", %{conn: conn} do
      [response_a, response_b] =
        [conn, conn]
        |> Enum.map(fn c ->
          Task.async(fn ->
            c
            |> post_batch(%{"operations" => [open_operation()]})
            |> json_response(200)
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert [%{"status" => "applied", "revision" => 1}] = response_a["results"]
      assert response_b == response_a

      assert get_group(conn, "group-81")["revision"] == 1
      assert Repo.aggregate(OperationRecord, :count) == 1
    end

    test "a retried credit-issuing cancellation does not mint a second lot", %{conn: conn} do
      open_group!(conn)
      submit_one(conn, payment_operation())

      cancel =
        payment_operation(%{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
        |> Map.delete("amount_cents")

      original = submit_one(conn, cancel)
      assert original["status"] == "applied"
      assert original["credit_issued_cents"] == 11000

      assert submit_one(conn, cancel) == original

      credit =
        conn
        |> get(~p"/api/v1/guests/guest-22/credit?on=2027-01-01")
        |> json_response(200)
        |> Map.fetch!("data")

      assert credit == %{
               "guest_id" => "guest-22",
               "available_cents" => 11000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 11000,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }
    end

    test "operations without an operation_id are processed without deduplication", %{conn: conn} do
      open_group!(conn)

      untracked =
        payment_operation()
        |> Map.delete("operation_id")
        |> Map.put("amount_cents", 5000)

      first = submit_one(conn, untracked)
      second = submit_one(conn, untracked)

      assert first["status"] == "applied"
      assert first["operation_id"] == nil
      assert second["status"] == "applied"
      assert second["revision"] == first["revision"] + 1

      assert get_group(conn, "group-81")["deposit_paid_cents"] == 10000
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result of an applied operation", %{conn: conn} do
      open_group!(conn)
      submit_one(conn, payment_operation())

      assert conn |> get_operation("op-pay") |> json_response(200) == %{
               "data" => %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 10000,
                 "outstanding_deposit_cents" => 9500,
                 "revision" => 2
               }
             }
    end

    test "returns the stored result of a rejected operation", %{conn: conn} do
      submit_one(conn, payment_operation())

      assert conn |> get_operation("op-pay") |> json_response(200) == %{
               "data" => %{
                 "operation_id" => "op-pay",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "group-81"
               }
             }
    end

    test "a result with a null field is returned intact", %{conn: conn} do
      open_group!(conn, %{"rate_plan" => "advance_purchase"})

      submit_one(conn, %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20"
      })

      %{"data" => result} = conn |> get_operation("op-move") |> json_response(200)

      assert result["refundable_until"] == nil
      assert Map.has_key?(result, "refundable_until")
    end

    test "an unknown operation_id returns 404", %{conn: conn} do
      assert conn
             |> get_operation("op-missing")
             |> json_response(404) == %{"error" => %{"code" => "operation_not_found"}}
    end
  end

  describe "the durable audit record" do
    test "retains the type and complete submission in commit order", %{conn: conn} do
      open_group!(conn, %{"operation_id" => "op-1"})
      submit_one(conn, payment_operation(%{"operation_id" => "op-2", "amount_cents" => 99_999}))
      submit_one(conn, %{"operation_id" => "op-3", "type" => "explode"})

      records = Repo.all(from r in OperationRecord, order_by: [asc: r.id])

      assert Enum.map(records, & &1.operation_id) == ["op-1", "op-2", "op-3"]
      assert Enum.map(records, & &1.type) == ["open_group", "record_cash_payment", "explode"]

      assert Enum.map(records, & &1.submission) == [
               open_operation(%{"operation_id" => "op-1"}),
               payment_operation(%{"operation_id" => "op-2", "amount_cents" => 99_999}),
               %{"operation_id" => "op-3", "type" => "explode"}
             ]

      assert Enum.map(records, & &1.result["status"]) == ["applied", "rejected", "rejected"]
    end

    test "an operation rejected as invalid is retained with its submitted content", %{conn: conn} do
      submit_one(conn, %{"operation_id" => "op-1", "extra" => %{"nested" => [1, 2]}})

      [record] = Repo.all(OperationRecord)

      assert record.operation_id == "op-1"
      assert record.type == nil
      assert record.submission == %{"operation_id" => "op-1", "extra" => %{"nested" => [1, 2]}}

      assert record.result == %{
               "operation_id" => "op-1",
               "status" => "rejected",
               "code" => "invalid_operation"
             }
    end
  end
end
