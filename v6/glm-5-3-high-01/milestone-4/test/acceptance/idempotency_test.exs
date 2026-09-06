defmodule GroupStay.AcceptanceIdempotencyTest do
  @moduledoc false

  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Schemas.OperationRecord

  describe "idempotent retries" do
    test "an identical retry returns the exact original result and changes nothing" do
      apply_operations!(build_conn(), [open_group_operation()])

      original =
        [
          payment_operation(%{
            "operation_id" => "op-pay",
            "amount_cents" => 1000,
            "expected_revision" => 1
          })
        ]
        |> submit_retry()

      conn =
        submit(build_conn(), [
          payment_operation(%{"amount_cents" => 1000, "expected_revision" => 1})
        ])

      assert json_response(conn, 200)["results"] == [original]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 1000

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_held_cents"] == 1000
    end

    test "a retry returns the original result even after later operations moved the group on" do
      apply_operations!(build_conn(), [open_group_operation()])

      original =
        [
          payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 1000})
        ]
        |> submit_retry()

      apply_operations!(build_conn(), [
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 2000})
      ])

      conn =
        submit(build_conn(), [
          payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 1000})
        ])

      assert json_response(conn, 200)["results"] == [original]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 3000
    end

    test "a replayed payment to a cancelled group returns the applied result, not group_not_active" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 1000}),
        cancel_operation()
      ])

      conn = submit(build_conn(), [payment_operation(%{"amount_cents" => 1000})])

      assert [%{"status" => "applied", "revision" => 2}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["revision"] == 3
    end

    test "JSON object key order is irrelevant to payload equivalence" do
      apply_operations!(build_conn(), [open_group_operation()])

      original =
        [
          payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 1000})
        ]
        |> submit_retry()

      reordered =
        """
        {"operations": [{"amount_cents": 1000, "occurred_on": "2026-10-04", \
        "group_id": "group-1", "type": "record_cash_payment", "operation_id": "op-pay"}]}
        """
        |> submit_raw()

      assert reordered == [original]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 1000
    end

    test "array order remains significant" do
      conn =
        submit(build_conn(), [
          open_group_operation(%{
            "operation_id" => "op-open",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
              %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
            ]
          })
        ])

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          open_group_operation(%{
            "operation_id" => "op-open",
            "rooms" => [
              %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
            ]
          })
        ])

      assert [%{"code" => "operation_id_conflict", "operation_id" => "op-open"}] =
               json_response(conn, 200)["results"]
    end

    test "rejected results are remembered and replayed even once they would succeed" do
      conn =
        submit(build_conn(), [
          payment_operation(%{"operation_id" => "op-pay", "group_id" => "missing"})
        ])

      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               json_response(conn, 200)["results"]

      apply_operations!(build_conn(), [
        open_group_operation(%{"group_id" => "missing", "operation_id" => "op-open"})
      ])

      conn = submit(build_conn(), [payment_operation(%{"group_id" => "missing"})])

      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/missing")
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 0
    end

    test "a rejected invalid operation is remembered under its identifier" do
      conn =
        submit(build_conn(), [
          %{
            "operation_id" => "op-weird",
            "type" => "rename_group",
            "group_id" => "group-1",
            "occurred_on" => "2026-10-03"
          }
        ])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          %{
            "operation_id" => "op-weird",
            "type" => "rename_group",
            "group_id" => "group-1",
            "occurred_on" => "2026-10-03"
          }
        ])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/operations/op-weird")

      assert json_response(conn, 200)["data"] == %{
               "operation_id" => "op-weird",
               "status" => "rejected",
               "code" => "invalid_operation"
             }
    end

    test "a stale revision result replays its original details verbatim" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 1000})
      ])

      original =
        [
          payment_operation(%{
            "operation_id" => "op-stale",
            "amount_cents" => 1000,
            "expected_revision" => 1
          })
        ]
        |> submit_first()

      assert original == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-1",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      apply_operations!(build_conn(), [
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 1000})
      ])

      conn =
        submit(build_conn(), [
          payment_operation(%{
            "operation_id" => "op-stale",
            "amount_cents" => 1000,
            "expected_revision" => 1
          })
        ])

      assert json_response(conn, 200)["results"] == [original]
    end

    test "retrying a stale operation with a corrected expected_revision is a conflict" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 1000})
      ])

      conn =
        submit(build_conn(), [
          payment_operation(%{
            "operation_id" => "op-stale",
            "amount_cents" => 1000,
            "expected_revision" => 1
          })
        ])

      assert [%{"code" => "stale_revision"}] = json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          payment_operation(%{
            "operation_id" => "op-stale",
            "amount_cents" => 1000,
            "expected_revision" => 2
          })
        ])

      assert [%{"code" => "operation_id_conflict", "operation_id" => "op-stale"}] =
               json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 1000
    end

    test "reusing an identifier with a different payload does not replace the original record" do
      apply_operations!(build_conn(), [open_group_operation()])

      original =
        [
          payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 1000})
        ]
        |> submit_retry()

      conn = submit(build_conn(), [payment_operation(%{"amount_cents" => 2000})])

      assert [%{"code" => "operation_id_conflict", "operation_id" => "op-pay"}] =
               json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["deposit_paid_cents"] == 1000
      assert data["revision"] == 2

      conn = submit(build_conn(), [payment_operation(%{"amount_cents" => 1000})])
      assert json_response(conn, 200)["results"] == [original]

      conn = get(build_conn(), "/api/v1/operations/op-pay")
      assert json_response(conn, 200)["data"] == original
    end

    test "the same identifier twice in one batch applies once" do
      apply_operations!(build_conn(), [open_group_operation()])

      conn =
        submit(build_conn(), [
          payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 1000}),
          payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 1000})
        ])

      results = json_response(conn, 200)["results"]
      assert Enum.map(results, & &1["revision"]) == [2, 2]
      assert Enum.uniq(results) == [hd(results)]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["deposit_paid_cents"] == 1000
      assert data["revision"] == 2
    end

    test "durable records retain type, submitted content, and commit order" do
      payment =
        open_group_operation(%{
          "operation_id" => "op-first",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        })

      reschedule = reschedule_operation(%{"operation_id" => "op-second"})

      apply_operations!(build_conn(), [payment, reschedule])

      records = Repo.all(from r in OperationRecord, order_by: r.id)

      assert Enum.map(records, & &1.operation_id) == ["op-first", "op-second"]
      assert Enum.map(records, & &1.type) == ["open_group", "reschedule_group"]
      assert Jason.decode!(Enum.at(records, 0).payload) == payment
      assert Jason.decode!(Enum.at(records, 1).payload) == reschedule
    end
  end

  defp submit_first(operations) do
    conn = submit(build_conn(), operations)
    assert [result] = json_response(conn, 200)["results"]
    assert result["status"] == "rejected", "expected rejected, got: #{inspect(result)}"
    result
  end

  defp submit_retry(operations) do
    conn = submit(build_conn(), operations)
    assert [result] = json_response(conn, 200)["results"]
    assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    result
  end

  defp submit_raw(body) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", body)

    json_response(conn, 200)["results"]
  end
end
