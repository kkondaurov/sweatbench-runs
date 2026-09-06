defmodule GroupStayWeb.Controllers.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @occurred_on "2026-10-03"

  describe "replaying an applied operation" do
    test "an identical retry returns the exact original result without applying again", %{
      conn: conn
    } do
      batch = [
        open_group_operation(),
        record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 10_000})
      ]

      assert %{"results" => first} = post_operations(conn, batch) |> json_response(200)

      assert %{"results" => replay} = post_operations(conn, batch) |> json_response(200)
      assert replay == first

      # The payment is applied exactly once.
      assert %{"revision" => 2, "deposit_paid_cents" => 10_000} = fetch_group!(conn, "group-81")

      assert ledger(conn) == %{
               "cash_held_cents" => 10_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "object key order is irrelevant, including inside nested objects", %{conn: conn} do
      conn =
        post_batch_body(conn, """
        {"operations":[{"operation_id":"op-order","type":"open_group",
          "occurred_on":"2026-10-03","group_id":"group-81","guest_id":"guest-22",
          "property_id":"ams-canal","arrival_on":"2026-12-10",
          "departure_on":"2026-12-13","rate_plan":"flexible",
          "rooms":[{"room_id":"room-a","nightly_rate_cents":15000}]}]}
        """)

      assert %{"results" => [original]} = json_response(conn, 200)
      assert original["status"] == "applied"

      conn =
        post_batch_body(conn, """
        {"operations":[{"rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"}],
          "rate_plan":"flexible","departure_on":"2026-12-13",
          "arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22",
          "group_id":"group-81","occurred_on":"2026-10-03","type":"open_group",
          "operation_id":"op-order"}]}
        """)

      assert %{"results" => [replay]} = json_response(conn, 200)
      assert replay == original

      assert %{"revision" => 1} = fetch_group!(conn, "group-81")
    end

    test "array order remains significant", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation(%{"operation_id" => "op-rooms"})])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      reordered =
        open_group_operation(%{
          "operation_id" => "op-rooms",
          "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
          ]
        })

      conn = post_operations(conn, [reordered])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
               json_response(conn, 200)

      # The original reservation is untouched.
      assert %{
               "rooms" => [
                 %{"room_id" => "room-a"},
                 %{"room_id" => "room-b"}
               ]
             } = fetch_group!(conn, "group-81")
    end

    test "a value difference is a conflict, not a new application", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_000})
        ])

      assert %{"results" => [_, original]} = json_response(conn, 200)

      conn =
        post_operations(conn, [
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_001})
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
               json_response(conn, 200)

      assert %{"revision" => 2, "deposit_paid_cents" => 5_000} = fetch_group!(conn, "group-81")
      assert get_operation(conn, "op-2") == original
    end

    test "replays do not read or change current domain state", %{conn: conn} do
      payment_op = record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 10_000})

      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_op
        ])

      assert %{"results" => [_, original]} = json_response(conn, 200)

      # Domain state moves on after the original attempt.
      conn =
        post_operations(conn, [
          record_payment_operation(%{"operation_id" => "op-3", "amount_cents" => 9_500})
        ])

      assert %{"results" => [%{"revision" => 3}]} = json_response(conn, 200)

      conn = post_operations(conn, [payment_op])

      assert %{"results" => [replay]} = json_response(conn, 200)
      assert replay == original
      assert %{"revision" => 3, "deposit_paid_cents" => 19_500} = fetch_group!(conn, "group-81")
    end
  end

  describe "replaying a rejected operation" do
    test "a rejection is remembered even when the operation would now succeed", %{conn: conn} do
      apply_op =
        apply_credit_operation(%{
          "operation_id" => "op-apply",
          "group_id" => "group-target",
          "amount_cents" => 4_000
        })

      conn =
        post_operations(conn, [
          open_group_operation(%{
            "operation_id" => "op-open-target",
            "group_id" => "group-target"
          }),
          apply_op
        ])

      assert %{"results" => [_, rejected]} = json_response(conn, 200)
      assert rejected["code"] == "insufficient_credit"

      # The guest later gains credit that would cover the application.
      conn = post_operations(conn, convert_cash_to_credit("group-source", "op-cancel-source"))

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = post_operations(conn, [apply_op])

      assert %{"results" => [replay]} = json_response(conn, 200)
      assert replay == rejected

      assert %{"revision" => 1, "credit_paid_cents" => 0} = fetch_group!(conn, "group-target")

      assert %{"available_cents" => 11_000} = guest_credit(conn, "guest-22")
    end

    test "a stale retry replays the revision observed on the original attempt", %{conn: conn} do
      stale_op =
        record_payment_operation(%{
          "operation_id" => "op-stale",
          "amount_cents" => 5_000,
          "expected_revision" => 1
        })

      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_000}),
          stale_op
        ])

      assert %{"results" => [_, _, stale]} = json_response(conn, 200)

      assert stale == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      # The group moves on to revision 3.
      conn =
        post_operations(conn, [
          record_payment_operation(%{"operation_id" => "op-4", "amount_cents" => 5_000})
        ])

      assert %{"results" => [%{"revision" => 3}]} = json_response(conn, 200)

      conn = post_operations(conn, [stale_op])

      assert %{"results" => [replay]} = json_response(conn, 200)
      assert replay == stale
      assert replay["actual_revision"] == 2
      assert %{"revision" => 3, "deposit_paid_cents" => 10_000} = fetch_group!(conn, "group-81")
    end

    test "retrying a stale operation with a corrected expected_revision is a conflict", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_000}),
          record_payment_operation(%{
            "operation_id" => "op-stale",
            "amount_cents" => 5_000,
            "expected_revision" => 1
          })
        ])

      assert %{"results" => [_, _, %{"code" => "stale_revision"}]} = json_response(conn, 200)

      conn =
        post_operations(conn, [
          record_payment_operation(%{
            "operation_id" => "op-stale",
            "amount_cents" => 5_000,
            "expected_revision" => 2
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
               json_response(conn, 200)

      assert %{"revision" => 2} = fetch_group!(conn, "group-81")
    end

    test "an invalid_operation rejection is remembered with its submitted type", %{conn: conn} do
      bad_op = %{
        "operation_id" => "op-bad",
        "type" => "mystery",
        "occurred_on" => @occurred_on,
        "group_id" => "group-81"
      }

      conn = post_operations(conn, [bad_op])

      assert %{"results" => [rejected]} = json_response(conn, 200)

      assert rejected == %{
               "operation_id" => "op-bad",
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      conn = post_operations(conn, [bad_op])
      assert %{"results" => [replay]} = json_response(conn, 200)
      assert replay == rejected
    end
  end

  describe "operation id conflicts" do
    test "a conflict does not replace the original record", %{conn: conn} do
      payment_op = record_payment_operation(%{"operation_id" => "op-y", "amount_cents" => 5_000})

      conn =
        post_operations(conn, [
          open_group_operation(%{"operation_id" => "op-x"}),
          payment_op
        ])

      assert %{"results" => [original_open, original_payment]} = json_response(conn, 200)

      conn =
        post_operations(conn, [
          record_payment_operation(%{"operation_id" => "op-y", "amount_cents" => 5_001})
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
               json_response(conn, 200)

      # The original record is intact: its result is still exposed and still
      # replays for an equivalent payload.
      assert get_operation(conn, "op-y") == original_payment

      conn = post_operations(conn, [payment_op])

      assert %{"results" => [replay]} = json_response(conn, 200)
      assert replay == original_payment

      assert get_operation(conn, "op-x") == original_open
    end

    test "two operations sharing an identifier in one batch apply at most once", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-dup", "amount_cents" => 5_000}),
          record_payment_operation(%{"operation_id" => "op-dup", "amount_cents" => 5_000}),
          record_payment_operation(%{
            "operation_id" => "op-dup",
            "type" => "record_cash_payment",
            "occurred_on" => @occurred_on,
            "group_id" => "group-81",
            "amount_cents" => 4_000
          })
        ])

      assert %{"results" => [_, first, second, third]} = json_response(conn, 200)

      assert first["status"] == "applied"
      assert second == first
      assert third["code"] == "operation_id_conflict"

      assert %{"revision" => 2, "deposit_paid_cents" => 5_000} = fetch_group!(conn, "group-81")
    end
  end

  describe "batch continuation" do
    test "replays and new operations continue in order", %{conn: conn} do
      payment_op = record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 10_000})

      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_op
        ])

      assert %{"results" => [_, payment]} = json_response(conn, 200)

      conn =
        post_operations(conn, [
          payment_op,
          record_payment_operation(%{"operation_id" => "op-3", "amount_cents" => 9_500}),
          %{
            "operation_id" => "op-4",
            "type" => "mystery",
            "occurred_on" => @occurred_on,
            "group_id" => "group-81"
          }
        ])

      assert %{"results" => [replay, applied, rejected]} = json_response(conn, 200)

      assert replay == payment
      assert applied["revision"] == 3
      assert rejected["code"] == "invalid_operation"

      assert %{"revision" => 3, "deposit_paid_cents" => 19_500} = fetch_group!(conn, "group-81")

      assert ledger(conn) == %{
               "cash_held_cents" => 19_500,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "an operation without a usable operation_id is rejected inline and not remembered", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          %{
            "type" => "record_cash_payment",
            "group_id" => "group-81",
            "occurred_on" => @occurred_on,
            "amount_cents" => 1_000
          }
        ])

      assert %{"results" => [_, %{"operation_id" => nil, "code" => "invalid_operation"}]} =
               json_response(conn, 200)

      assert_operation_found(conn, "op-1001")
      assert_operation_not_found(conn, "op-missing")
    end
  end

  describe "unexpected server faults" do
    test "an unexpected exception is not remembered and allows a corrected retry", %{
      conn: conn
    } do
      # The nightly rate overflows SQLite's integer range: validation passes,
      # the domain insert fails, and the fault is not a handled rejection.
      huge = 9_223_372_036_854_775_808

      conn =
        post_operations(conn, [
          open_group_operation(%{"operation_id" => "op-1", "group_id" => "group-keep"})
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      faulting =
        open_group_operation(%{
          "operation_id" => "op-2",
          "group_id" => "group-huge",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => huge}]
        })

      assert_raise Exqlite.Error, fn ->
        post_operations(conn, [faulting])
      end

      # The earlier operation survived; the faulting one left no record.
      assert %{"revision" => 1} = fetch_group!(conn, "group-keep")
      assert_operation_not_found(conn, "op-2")

      # The gateway may retry: the same identifier with a corrected payload is
      # processed normally because nothing was remembered.
      conn =
        post_operations(conn, [
          open_group_operation(%{"operation_id" => "op-2", "group_id" => "group-retry"})
        ])

      assert %{"results" => [%{"status" => "applied", "group_id" => "group-retry"}]} =
               json_response(conn, 200)

      assert_operation_found(conn, "op-2")
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "exposes the stored result of an applied operation", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 5_000})
        ])

      assert %{"results" => [_, payment]} = json_response(conn, 200)
      assert get_operation(conn, "op-2") == payment
    end

    test "exposes the stored result of a rejected operation", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"operation_id" => "op-2", "amount_cents" => 99_999})
        ])

      assert %{"results" => [_, rejected]} = json_response(conn, 200)
      assert rejected["status"] == "rejected"
      assert get_operation(conn, "op-2") == rejected
    end

    test "returns 404 operation_not_found for an unknown identifier", %{conn: conn} do
      response = get(conn, "/api/v1/operations/never-seen")
      assert json_response(response, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end
  end

  describe "durable records" do
    test "records survive as an audit trail in first-commit order", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{"operation_id" => "op-1"}),
          %{
            "operation_id" => "op-2",
            "type" => "mystery",
            "occurred_on" => @occurred_on,
            "group_id" => "group-81"
          },
          record_payment_operation(%{"operation_id" => "op-3", "amount_cents" => 5_000})
        ])

      assert %{"results" => [_, _, _]} = json_response(conn, 200)

      conn =
        post_operations(conn, [
          record_payment_operation(%{"operation_id" => "op-4", "amount_cents" => 5_000})
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      records = records_in_commit_order()

      assert Enum.map(records, & &1.operation_id) == ["op-1", "op-2", "op-3", "op-4"]
      assert Enum.map(records, & &1.sequence) == [1, 2, 3, 4]

      assert Enum.map(records, & &1.type) == [
               "open_group",
               "mystery",
               "record_cash_payment",
               "record_cash_payment"
             ]

      # The retained submission is the complete operation content.
      assert Jason.decode!(hd(records).payload) == %{
               "operation_id" => "op-1",
               "type" => "open_group",
               "occurred_on" => @occurred_on,
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
             }

      # A replay neither adds a record nor disturbs the committed order.
      conn = post_operations(conn, [open_group_operation(%{"operation_id" => "op-1"})])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert Enum.map(records_in_commit_order(), & &1.operation_id) == [
               "op-1",
               "op-2",
               "op-3",
               "op-4"
             ]
    end

    test "concurrent retries have at-most-once effects", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      payment = record_payment_operation(%{"operation_id" => "op-dup", "amount_cents" => 5_000})

      results =
        1..4
        |> Task.async_stream(fn _ ->
          assert %{"results" => [result]} =
                   post_operations(build_conn(), [payment]) |> json_response(200)

          result
        end)
        |> Enum.map(&elem(&1, 1))

      # Every retry observes the same single application.
      assert Enum.uniq(results) == [
               %{
                 "operation_id" => "op-dup",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]

      assert %{"revision" => 2, "deposit_paid_cents" => 5_000} = fetch_group!(conn, "group-81")
      assert %{"cash_held_cents" => 5_000} = ledger(conn)
    end
  end

  defp record_payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => @occurred_on,
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-25",
        "group_id" => "group-81",
        "amount_cents" => 4_000
      },
      overrides
    )
  end

  defp get_operation(conn, operation_id) do
    assert %{"data" => result} =
             json_response(get(conn, "/api/v1/operations/#{operation_id}"), 200)

    result
  end

  defp assert_operation_found(conn, operation_id) do
    refute is_nil(get_operation(conn, operation_id))
  end

  defp assert_operation_not_found(conn, operation_id) do
    response = get(conn, "/api/v1/operations/#{operation_id}")

    assert json_response(response, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end

  defp convert_cash_to_credit(group_id, operation_id) do
    [
      open_group_operation(%{"group_id" => group_id, "operation_id" => operation_id <> "-open"}),
      record_payment_operation(%{
        "group_id" => group_id,
        "operation_id" => operation_id <> "-pay",
        "amount_cents" => 10_000
      }),
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      }
    ]
  end

  defp records_in_commit_order do
    Repo.all(from r in Record, order_by: [asc: r.sequence])
  end

  defp ledger(conn) do
    assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger"), 200)
    data
  end

  defp guest_credit(conn, guest_id) do
    assert %{"data" => data} = json_response(get(conn, "/api/v1/guests/#{guest_id}/credit"), 200)
    data
  end
end
