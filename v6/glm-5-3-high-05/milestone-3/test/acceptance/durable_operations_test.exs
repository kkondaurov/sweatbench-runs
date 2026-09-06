defmodule GroupStayWeb.Acceptance.DurableOperationsTest do
  @moduledoc """
  Durable idempotency of partner operations on `operation_id`.
  """

  use GroupStayWeb.ConnCase, async: true

  alias GroupStay.Repo

  describe "retrying an applied operation" do
    test "an exact retry returns the original result and leaves domain state unchanged" do
      open_group!(build_conn(), %{"operation_id" => "op-1", "group_id" => "group-81"})

      original =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"operation_id" => "op-2", "amount_cents" => 5000})
        )

      assert %{"status" => "applied", "revision" => 2} = original

      retry =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"operation_id" => "op-2", "amount_cents" => 5000})
        )

      assert retry == original
      assert group_data("group-81")["revision"] == 2
      assert group_data("group-81")["deposit_paid_cents"] == 5000
    end

    test "a retry replays without reading current domain state" do
      open_group!(build_conn(), %{"operation_id" => "op-1", "group_id" => "group-81"})

      original =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"operation_id" => "op-2", "amount_cents" => 5000})
        )

      # The group is cancelled after the recorded payment; the retry must not
      # observe that, it replays the stored result instead.
      apply_one!(
        build_conn(),
        cancel_operation(%{
          "operation_id" => "op-3",
          "group_id" => "group-81",
          "occurred_on" => "2026-11-26"
        })
      )

      retry =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"operation_id" => "op-2", "amount_cents" => 5000})
        )

      assert retry == original
    end

    test "an exact retry of an open_group replays rather than colliding" do
      original = open_group!(build_conn(), %{"operation_id" => "op-1"})

      retry = apply_one!(build_conn(), open_group_operation(%{"operation_id" => "op-1"}))

      assert retry == original
      assert group_data("group-81")["revision"] == 1
    end

    test "object key order in the payload is irrelevant" do
      original = open_group!(build_conn(), %{"operation_id" => "op-1"})

      # The same payload with the object keys submitted in a different order.
      raw =
        ~s({"operations":[{"type":"open_group","rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},{"room_id":"room-b","nightly_rate_cents":17500}],"departure_on":"2026-12-13","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22","group_id":"group-81","occurred_on":"2026-10-03","operation_id":"op-1","rate_plan":"flexible"}]})

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", raw)

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result == original
    end

    test "array order remains significant" do
      open_group!(build_conn(), %{"operation_id" => "op-1"})

      reordered =
        open_group_operation(%{
          "operation_id" => "op-1",
          "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
          ]
        })

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               apply_one!(build_conn(), reordered)
    end
  end

  describe "retrying a rejected operation" do
    test "a rejected result is remembered even when the operation would now be valid" do
      rejected =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"operation_id" => "op-pay", "group_id" => "group-none"})
        )

      assert %{"status" => "rejected", "code" => "group_not_found"} = rejected

      # The group now exists; the retry still receives the original rejection.
      open_group!(build_conn(), %{"group_id" => "group-none"})

      retry =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"operation_id" => "op-pay", "group_id" => "group-none"})
        )

      assert retry == rejected
      assert group_data("group-none")["revision"] == 1
      assert group_data("group-none")["deposit_paid_cents"] == 0
    end

    test "a rejected operation commits its record but leaves domain state unchanged" do
      open_group!(build_conn(), %{"group_id" => "group-81"})
      before = group_data("group-81")

      assert %{"status" => "rejected", "code" => "invalid_amount"} =
               apply_one!(
                 build_conn(),
                 record_cash_operation(%{
                   "operation_id" => "op-bad",
                   "group_id" => "group-81",
                   "amount_cents" => 0
                 })
               )

      assert group_data("group-81") == before

      assert %{"data" => %{"status" => "rejected", "code" => "invalid_amount"}} =
               get_operation("op-bad")
    end

    test "a stale revision result is replayed verbatim" do
      open_group!(build_conn(), %{"group_id" => "group-81"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000})
      )

      stale =
        apply_one!(
          build_conn(),
          record_cash_operation(%{
            "operation_id" => "op-stale",
            "expected_revision" => 1,
            "amount_cents" => 1000
          })
        )

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "expected_revision" => 1,
               "actual_revision" => 2
             } = stale

      retry =
        apply_one!(
          build_conn(),
          record_cash_operation(%{
            "operation_id" => "op-stale",
            "expected_revision" => 1,
            "amount_cents" => 1000
          })
        )

      assert retry == stale
      assert group_data("group-81")["revision"] == 2
    end
  end

  describe "payload conflicts" do
    test "a different payload is rejected and does not replace the original record" do
      original = open_group!(build_conn(), %{"operation_id" => "op-1"})

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               apply_one!(
                 build_conn(),
                 open_group_operation(%{"operation_id" => "op-1", "property_id" => "bru-grand"})
               )

      # The original record survives: an exact retry still replays it.
      assert apply_one!(build_conn(), open_group_operation(%{"operation_id" => "op-1"})) ==
               original
    end

    test "retrying a stale operation with a corrected expected_revision conflicts" do
      open_group!(build_conn(), %{"group_id" => "group-81"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000})
      )

      assert %{"code" => "stale_revision"} =
               apply_one!(
                 build_conn(),
                 record_cash_operation(%{
                   "operation_id" => "op-stale",
                   "expected_revision" => 1,
                   "amount_cents" => 1000
                 })
               )

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               apply_one!(
                 build_conn(),
                 record_cash_operation(%{
                   "operation_id" => "op-stale",
                   "expected_revision" => 2,
                   "amount_cents" => 1000
                 })
               )
    end

    test "a conflict does not stop later operations in the batch" do
      open_group!(build_conn(), %{"operation_id" => "op-1", "group_id" => "group-81"})

      conn =
        post_batch(build_conn(), [
          open_group_operation(%{"operation_id" => "op-1", "property_id" => "bru-grand"}),
          record_cash_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000})
        ])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "operation_id_conflict"},
                 %{"status" => "applied", "revision" => 2}
               ]
             } = json_response(conn, 200)
    end
  end

  describe "reading a stored operation" do
    test "an applied operation returns its stored result" do
      original = open_group!(build_conn(), %{"operation_id" => "op-1"})

      conn = get(build_conn(), "/api/v1/operations/op-1")
      assert %{"data" => data} = json_response(conn, 200)
      assert data == original
    end

    test "a rejected operation returns its stored result" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-bad", "group_id" => "group-none"})
      )

      conn = get(build_conn(), "/api/v1/operations/op-bad")

      assert %{"data" => %{"status" => "rejected", "code" => "group_not_found"}} =
               json_response(conn, 200)
    end

    test "an unknown operation is a 404 with operation_not_found" do
      conn = get(build_conn(), "/api/v1/operations/op-nope")

      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
    end

    test "the endpoint exposes only the stored result" do
      open_group!(build_conn(), %{"operation_id" => "op-1"})

      conn = get(build_conn(), "/api/v1/operations/op-1")
      {:ok, body} = Jason.decode(response(conn, 200))

      assert Map.has_key?(body, "data")
      refute Map.has_key?(body, "payload")
      refute Map.has_key?(body, "committed_at")

      data_keys = Map.keys(body["data"])
      refute "payload" in data_keys
      refute "type" in data_keys
    end
  end

  describe "replaying a whole batch" do
    test "a resubmitted batch replays every stored result without new effects" do
      operations = [
        open_group_operation(%{"operation_id" => "op-1"}),
        record_cash_operation(%{"operation_id" => "op-2", "amount_cents" => 0}),
        cancel_operation(%{"operation_id" => "op-3", "occurred_on" => "2026-11-26"})
      ]

      conn = post_batch(build_conn(), operations)
      assert {:ok, first} = Jason.decode(response(conn, 200))

      conn = post_batch(build_conn(), operations)
      assert {:ok, replay} = Jason.decode(response(conn, 200))

      assert replay == first
      assert group_data("group-81")["status"] == "cancelled"
      assert group_data("group-81")["revision"] == 2
    end
  end

  describe "unexpected faults" do
    test "an unexpected exception aborts the batch with 500 and is not remembered" do
      open_group!(build_conn(), %{"operation_id" => "op-open", "group_id" => "group-81"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000})
      )

      # A refundable cancellation paid with hotel credit stores the
      # operation_id as the credit lot's source. A non-string identifier
      # cannot be stored there, so the operation raises after validation: an
      # unexpected fault rather than a handled rejection.
      conn =
        post_batch(build_conn(), [
          record_cash_operation(%{"operation_id" => 1, "amount_cents" => 1000}),
          cancel_operation(%{
            "operation_id" => 2,
            "refund_method" => "hotel_credit",
            "occurred_on" => "2026-11-26"
          }),
          cancel_operation(%{"operation_id" => "op-cancel", "occurred_on" => "2026-11-26"})
        ])

      assert %{status: 500} = conn

      # Earlier operations committed and are remembered.
      assert %{"data" => %{"status" => "applied", "revision" => 2}} = get_operation("op-pay-1")

      # The failing operation and everything after it are not remembered.
      recorded = GroupStay.Operations.records() |> Enum.map(& &1.operation_key)
      assert recorded == [Jason.encode!("op-open"), Jason.encode!("op-pay-1"), Jason.encode!(1)]

      # The failed operation left no domain change behind.
      group = group_data("group-81")
      assert group["status"] == "active"
      assert group["revision"] == 3
      assert group["deposit_paid_cents"] == 6000
      assert group["credit_paid_cents"] == 0

      # Retrying the batch replays the committed part and fails again.
      conn =
        post_batch(build_conn(), [
          record_cash_operation(%{"operation_id" => 1, "amount_cents" => 1000}),
          cancel_operation(%{
            "operation_id" => 2,
            "refund_method" => "hotel_credit",
            "occurred_on" => "2026-11-26"
          })
        ])

      assert %{status: 500} = conn
      assert group_data("group-81")["revision"] == 3
      assert group_data("group-81")["deposit_paid_cents"] == 6000
    end
  end

  describe "the durable audit record" do
    test "retains type, submitted content, and commit order" do
      post_batch(build_conn(), [
        open_group_operation(%{"operation_id" => "op-1"}),
        record_cash_operation(%{"operation_id" => "op-2", "amount_cents" => 5000}),
        record_cash_operation(%{"operation_id" => "op-3", "group_id" => "group-none"})
      ])

      records = GroupStay.Operations.records()

      assert Enum.map(records, & &1.operation_key) ==
               [Jason.encode!("op-1"), Jason.encode!("op-2"), Jason.encode!("op-3")]

      assert Enum.map(records, & &1.id) == Enum.sort(Enum.map(records, & &1.id))

      assert Enum.map(records, & &1.type) == [
               "open_group",
               "record_cash_payment",
               "record_cash_payment"
             ]

      assert Enum.map(records, & &1.status) == ["applied", "applied", "rejected"]

      [open_payload, _pay_payload, _rejected_payload] = Enum.map(records, & &1.payload)

      assert {:ok, decoded} = Jason.decode(open_payload)
      assert decoded == open_group_operation(%{"operation_id" => "op-1"})
    end

    test "operations without a usable operation_id are not recorded" do
      apply_one!(build_conn(), Map.delete(open_group_operation(), "operation_id"))

      assert GroupStay.Operations.records() == []
      assert Repo.aggregate(GroupStay.Operations.Record, :count) == 0
    end
  end

  defp group_data(group_id) do
    assert %{status: 200} = conn = get_group(build_conn(), group_id)
    json_response(conn, 200)["data"]
  end

  defp get_operation(operation_id) do
    conn = Phoenix.ConnTest.get(build_conn(), "/api/v1/operations/#{operation_id}")
    {:ok, body} = Jason.decode(response(conn, conn.status))
    body
  end
end
