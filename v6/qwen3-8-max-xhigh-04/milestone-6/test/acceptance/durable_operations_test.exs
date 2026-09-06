defmodule GroupStayWeb.Acceptance.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @open_op %{
    "operation_id" => "op-1",
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
  }

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit_raw(conn, raw_json) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", raw_json)
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_group(conn, overrides \\ %{}) do
    [result] = submit(conn, [Map.merge(@open_op, overrides)])
    assert %{"status" => "applied"} = result
    result
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  defp stored_result(conn, operation_id) do
    conn
    |> get("/api/v1/operations/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp group(conn) do
    conn
    |> get("/api/v1/groups/group-81")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp records do
    Repo.all(from record in Record, order_by: record.id)
  end

  describe "retry behavior" do
    test "the first operation for an identifier is processed normally" do
      assert [%{"status" => "applied", "revision" => 1}] = submit(build_conn(), [@open_op])
    end

    test "an exact retry returns the original result without applying again" do
      open_group(build_conn())

      [first] = submit(build_conn(), [payment_op()])
      assert first["status"] == "applied"
      assert first["revision"] == 2
      assert first["outstanding_deposit_cents"] == 14500

      assert submit(build_conn(), [payment_op()]) == [first]

      group = group(build_conn())
      assert group["deposit_paid_cents"] == 5000
      assert group["revision"] == 2
    end

    test "object key order is irrelevant for retries" do
      [original] = submit(build_conn(), [@open_op])

      reordered =
        ~s({"operations":[{"type":"open_group","rooms":[) <>
          ~s({"nightly_rate_cents":15000,"room_id":"room-a"},) <>
          ~s({"nightly_rate_cents":17500,"room_id":"room-b"}],) <>
          ~s("rate_plan":"flexible","departure_on":"2026-12-13",) <>
          ~s("arrival_on":"2026-12-10","property_id":"ams-canal",) <>
          ~s("guest_id":"guest-22","group_id":"group-81",) <>
          ~s("occurred_on":"2026-10-03","operation_id":"op-1"}]})

      assert submit_raw(build_conn(), reordered) == [original]
      assert group(build_conn())["revision"] == 1
    end

    test "array order remains significant" do
      open_group(build_conn())

      reversed_rooms = Map.update!(@open_op, "rooms", &Enum.reverse/1)

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               submit(build_conn(), [reversed_rooms])
    end

    test "changed values remain significant" do
      open_group(build_conn())

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               submit(build_conn(), [Map.put(@open_op, "rate_plan", "advance_purchase")])
    end

    test "distinct JSON number representations are different payloads" do
      open_group(build_conn())
      submit(build_conn(), [payment_op()])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               submit(build_conn(), [payment_op(%{"amount_cents" => 5000.0})])
    end

    test "a remembered rejection is returned even when later operations would make it valid" do
      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               submit(build_conn(), [payment_op()])

      open_group(build_conn())

      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               submit(build_conn(), [payment_op()])

      group = group(build_conn())
      assert group["deposit_paid_cents"] == 0
      assert group["revision"] == 1
    end

    test "a retry returns stale-revision details verbatim without consulting current state" do
      open_group(build_conn())
      submit(build_conn(), [payment_op()])

      [stale] =
        submit(build_conn(), [
          payment_op(%{"operation_id" => "op-stale", "expected_revision" => 1})
        ])

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 2

      submit(build_conn(), [payment_op(%{"operation_id" => "op-pay-2"})])
      assert group(build_conn())["revision"] == 3

      [retried] =
        submit(build_conn(), [
          payment_op(%{"operation_id" => "op-stale", "expected_revision" => 1})
        ])

      assert retried == stale
    end

    test "a corrected expected_revision under the same identifier is a conflict" do
      open_group(build_conn())
      submit(build_conn(), [payment_op()])

      assert [%{"status" => "rejected", "code" => "stale_revision"}] =
               submit(build_conn(), [
                 payment_op(%{"operation_id" => "op-stale", "expected_revision" => 1})
               ])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               submit(build_conn(), [
                 payment_op(%{"operation_id" => "op-stale", "expected_revision" => 2})
               ])

      assert stored_result(build_conn(), "op-stale")["code"] == "stale_revision"
      assert group(build_conn())["revision"] == 2
    end

    test "a conflict does not replace the original record" do
      open_group(build_conn())

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               submit(build_conn(), [Map.put(@open_op, "group_id", "group-other")])

      assert stored_result(build_conn(), "op-1")["status"] == "applied"

      assert [%{"status" => "applied"}] = submit(build_conn(), [@open_op])
    end

    test "a conflict does not stop later operations in the batch" do
      open_group(build_conn())

      assert [
               %{"status" => "rejected", "code" => "operation_id_conflict"},
               %{"status" => "applied", "revision" => 2}
             ] =
               submit(build_conn(), [
                 Map.put(@open_op, "group_id", "group-other"),
                 payment_op()
               ])
    end

    test "the same identifier twice in one batch replays or conflicts" do
      assert [%{"status" => "applied"}, %{"status" => "applied"}] =
               submit(build_conn(), [@open_op, @open_op])

      assert group(build_conn())["revision"] == 1
    end

    test "the same identifier with a different payload in one batch conflicts" do
      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "operation_id_conflict"}
             ] =
               submit(build_conn(), [
                 @open_op,
                 Map.put(@open_op, "group_id", "group-other")
               ])
    end

    test "operations without an identifier are processed but not remembered" do
      untracked = Map.delete(@open_op, "operation_id")

      assert [%{"status" => "applied"}] = submit(build_conn(), [untracked])

      assert [%{"status" => "rejected", "code" => "group_already_exists"}] =
               submit(build_conn(), [untracked])
    end

    test "concurrent retries apply the operation at most once" do
      tasks =
        for _ <- 1..4 do
          Task.async(fn ->
            build_conn()
            |> post("/api/v1/partner-batches", %{"operations" => [@open_op]})
            |> json_response(200)
            |> Map.fetch!("results")
          end)
        end

      [first | rest] = Enum.map(tasks, &Task.await/1)

      assert [%{"status" => "applied", "revision" => 1}] = first
      assert Enum.all?(rest, &(&1 == first))

      assert group(build_conn())["revision"] == 1
      assert Repo.aggregate(Group, :count) == 1
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result of an applied operation" do
      [result] = submit(build_conn(), [@open_op])

      assert stored_result(build_conn(), "op-1") == result
    end

    test "returns the stored result of a rejected operation" do
      [rejection] = submit(build_conn(), [payment_op()])
      assert rejection["status"] == "rejected"

      assert stored_result(build_conn(), "op-pay") == rejection
    end

    test "exposes only the stored result" do
      submit(build_conn(), [@open_op])

      conn = get(build_conn(), "/api/v1/operations/op-1")
      assert %{"data" => _} = json_response(conn, 200)
    end

    test "a missing operation returns 404 operation_not_found" do
      conn = get(build_conn(), "/api/v1/operations/never-seen")

      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end
  end

  describe "durable audit record" do
    test "retains type and complete submitted content in first-commit order" do
      open_group(build_conn())

      submit(build_conn(), [
        payment_op(),
        payment_op(%{"operation_id" => "op-pay-bad", "amount_cents" => 0})
      ])

      [first, second, third] = records()

      assert Enum.map([first, second, third], & &1.operation_id) ==
               ["op-1", "op-pay", "op-pay-bad"]

      assert first.type == "open_group"
      assert second.type == "record_cash_payment"
      assert third.type == "record_cash_payment"

      assert Jason.decode!(first.payload) == @open_op
      assert Jason.decode!(second.payload) == payment_op()

      assert Jason.decode!(third.payload) ==
               payment_op(%{"operation_id" => "op-pay-bad", "amount_cents" => 0})

      assert Jason.decode!(first.result)["status"] == "applied"
      assert Jason.decode!(third.result)["code"] == "invalid_amount"
    end

    test "retries and conflicts do not add or reorder records" do
      open_group(build_conn())

      before = Enum.map(records(), & &1.id)

      submit(build_conn(), [@open_op])
      submit(build_conn(), [Map.put(@open_op, "group_id", "group-other")])

      assert Enum.map(records(), & &1.id) == before
    end
  end

  describe "unexpected failures" do
    test "an exception rolls back the operation, is not remembered, and aborts the batch" do
      submit(build_conn(), [@open_op, payment_op()])

      # Fault injection: the cancellation below will fail while issuing credit.
      Repo.query!("DROP TABLE credit_lots")

      crashing_batch = [
        payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1000}),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81",
          "refund_method" => "hotel_credit"
        }
      ]

      assert {500, _headers, body} =
               assert_error_sent(500, fn ->
                 post(build_conn(), "/api/v1/partner-batches", %{
                   "operations" => crashing_batch
                 })
               end)

      assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}

      assert stored_result(build_conn(), "op-pay-2")["status"] == "applied"

      assert json_response(get(build_conn(), "/api/v1/operations/op-cancel"), 404) ==
               %{"error" => %{"code" => "operation_not_found"}}

      group = group(build_conn())
      assert group["status"] == "active"
      assert group["revision"] == 3
      assert group["deposit_paid_cents"] == 6000
    end
  end
end
