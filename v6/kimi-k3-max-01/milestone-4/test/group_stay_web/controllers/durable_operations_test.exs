defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  alias GroupStay.Groups

  # Posts a raw JSON body so the exact submitted key order is under test
  # control, the way the gateway sends it.
  defp post_raw_batch!(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", body)
    |> json_response(200)
    |> Map.fetch!("results")
  end

  describe "idempotent retries" do
    test "an exact retry of an applied operation replays the stored result", %{conn: conn} do
      [_opened, original] =
        apply_batch!(conn, [open_group_op(), record_cash_payment_op()])

      [replay] = post_batch!(fresh_conn(), [record_cash_payment_op()])

      assert replay == original

      # The payment was applied exactly once.
      group = get_group!(fresh_conn(), "group-81")
      assert group["deposit_paid_cents"] == 10_000
      assert group["revision"] == 2
      assert get_ledger!(fresh_conn())["cash_held_cents"] == 10_000
    end

    test "an exact retry of open_group replays the result instead of rejecting the duplicate", %{
      conn: conn
    } do
      [original] = apply_batch!(conn, [open_group_op()])

      [replay] = post_batch!(fresh_conn(), [open_group_op()])

      assert replay == original
      assert replay["status"] == "applied"
      assert Groups.get_group("group-81").revision == 1
    end

    test "a retry within the same batch replays the stored result", %{conn: conn} do
      results =
        post_batch!(conn, [
          open_group_op(),
          record_cash_payment_op(),
          record_cash_payment_op()
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "outstanding_deposit_cents" => 9_500},
               %{"status" => "applied", "outstanding_deposit_cents" => 9_500}
             ] = results

      assert Enum.at(results, 1) == Enum.at(results, 2)
      assert Groups.get_group("group-81").deposit_paid_cents == 10_000
    end

    test "JSON object key order is irrelevant", %{conn: conn} do
      apply_batch!(conn, [open_group_op()])

      [original] =
        post_raw_batch!(fresh_conn(), ~s"""
        {"operations": [
          {"operation_id": "op-raw", "type": "record_cash_payment",
           "occurred_on": "2026-10-04", "group_id": "group-81", "amount_cents": 10000}
        ]}
        """)

      # The same operation with its keys in a different order.
      [replay] =
        post_raw_batch!(fresh_conn(), ~s"""
        {"operations": [
          {"amount_cents": 10000, "group_id": "group-81", "occurred_on": "2026-10-04",
           "type": "record_cash_payment", "operation_id": "op-raw"}
        ]}
        """)

      assert replay == original
      assert Groups.get_group("group-81").deposit_paid_cents == 10_000
    end

    test "array order and values remain significant", %{conn: conn} do
      [original] = apply_batch!(conn, [open_group_op()])
      assert original["status"] == "applied"

      # Same identifier, but the rooms array is ordered differently.
      [conflict] =
        post_batch!(fresh_conn(), [
          open_group_op(%{
            "rooms" => [
              %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
            ]
          })
        ])

      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"

      # Same identifier, but one value differs.
      [conflict] =
        post_batch!(fresh_conn(), [
          open_group_op(%{"property_id" => "ams-zuid"})
        ])

      assert conflict["code"] == "operation_id_conflict"
    end

    test "a rejected result is replayed even when the operation would now be valid", %{conn: conn} do
      [original] = post_batch!(conn, [record_cash_payment_op()])
      assert original["code"] == "group_not_found"

      # The group now exists and the payment would apply, but the retry must
      # receive the original rejection.
      open_group!(fresh_conn(), %{"operation_id" => "op-1001"})

      [replay] = post_batch!(fresh_conn(), [record_cash_payment_op()])

      assert replay == original
      assert Groups.get_group("group-81").deposit_paid_cents == 0
    end

    test "an invalid_operation rejection is remembered like any other result", %{conn: conn} do
      operation = open_group_op(%{"type" => "hold_group"})

      [original] = post_batch!(conn, [operation])
      assert original["code"] == "invalid_operation"

      [replay] = post_batch!(fresh_conn(), [operation])
      assert replay == original

      # Correcting the type under the same identifier is a different payload.
      [conflict] = post_batch!(fresh_conn(), [open_group_op()])

      assert conflict == %{
               "operation_id" => "op-1001",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert Groups.get_group("group-81") == nil
    end

    test "a conflicting payload does not replace the original record", %{conn: conn} do
      [_opened, original] =
        apply_batch!(conn, [open_group_op(), record_cash_payment_op()])

      [conflict] =
        post_batch!(fresh_conn(), [record_cash_payment_op(%{"amount_cents" => 5_000})])

      assert conflict == %{
               "operation_id" => "op-2001",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      # The original record still answers exact retries.
      [replay] = post_batch!(fresh_conn(), [record_cash_payment_op()])
      assert replay == original

      group = get_group!(fresh_conn(), "group-81")
      assert group["deposit_paid_cents"] == 10_000
      assert group["revision"] == 2
    end

    test "a conflict is a handled rejection: the batch continues in order", %{conn: conn} do
      apply_batch!(conn, [open_group_op(), record_cash_payment_op()])

      results =
        post_batch!(fresh_conn(), [
          record_cash_payment_op(%{"amount_cents" => 5_000}),
          record_cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 5_000})
        ])

      assert [
               %{"status" => "rejected", "code" => "operation_id_conflict"},
               %{"status" => "applied", "outstanding_deposit_cents" => 4_500, "revision" => 3}
             ] = results
    end

    test "the exact-result guarantee includes stale-revision details", %{conn: conn} do
      apply_batch!(conn, [open_group_op(), record_cash_payment_op()])

      stale_op =
        record_cash_payment_op(%{
          "operation_id" => "op-stale",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        })

      [original] = post_batch!(fresh_conn(), [stale_op])

      assert original == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      # The group's revision moves on; the replay still reports the original
      # actual_revision without consulting current state.
      apply_batch!(fresh_conn(), [
        record_cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 1_000})
      ])

      assert Groups.get_group("group-81").revision == 3

      [replay] = post_batch!(fresh_conn(), [stale_op])
      assert replay == original

      # Retrying with a corrected expected_revision is a different payload.
      [conflict] =
        post_batch!(fresh_conn(), [
          record_cash_payment_op(%{
            "operation_id" => "op-stale",
            "amount_cents" => 1_000,
            "expected_revision" => 3
          })
        ])

      assert conflict["code"] == "operation_id_conflict"
    end

    test "a credit-issuing cancellation is applied at most once", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500})
      ])

      cancel_op = cancel_group_op(%{"refund_method" => "hotel_credit"})

      [original] = apply_batch!(fresh_conn(), [cancel_op])
      assert original["credit_issued_cents"] == 21_450

      [replay] = post_batch!(fresh_conn(), [cancel_op])
      assert replay == original

      # No second lot was issued.
      credit = get_credit!(fresh_conn(), "guest-22")

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-4001",
                 "remaining_cents" => 21_450,
                 "expires_on" => "2027-11-02"
               }
             ]

      assert get_ledger!(fresh_conn())["cash_converted_to_credit_cents"] == 19_500
    end

    test "operations without a usable identifier are processed but not remembered", %{conn: _conn} do
      operation = open_group_op() |> Map.delete("operation_id")

      for _attempt <- 1..2 do
        [result] = post_batch!(fresh_conn(), [operation])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
        assert result["operation_id"] == nil
      end
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result of an applied operation", %{conn: conn} do
      [_opened, original] =
        apply_batch!(conn, [open_group_op(), record_cash_payment_op()])

      assert get_operation!(fresh_conn(), "op-2001") == original
    end

    test "returns the stored result of a rejected operation", %{conn: conn} do
      [original] = post_batch!(conn, [record_cash_payment_op()])
      assert original["status"] == "rejected"

      assert get_operation!(fresh_conn(), "op-2001") == original
    end

    test "still returns the original result after a conflicting submission", %{conn: conn} do
      [original] = apply_batch!(conn, [open_group_op()])

      [conflict] =
        post_batch!(fresh_conn(), [open_group_op(%{"guest_id" => "guest-99"})])

      assert conflict["code"] == "operation_id_conflict"
      assert get_operation!(fresh_conn(), "op-1001") == original
    end

    test "returns 404 for an unknown identifier", %{conn: conn} do
      response =
        conn
        |> get(~p"/api/v1/operations/op-never-seen")
        |> json_response(404)

      assert response == %{"error" => %{"code" => "operation_not_found"}}
    end
  end
end
