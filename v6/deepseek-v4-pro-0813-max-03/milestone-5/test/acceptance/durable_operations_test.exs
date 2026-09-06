defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  defp json_header(conn) do
    put_req_header(conn, "content-type", "application/json")
  end

  defp submit_batch(conn, operations) do
    conn
    |> json_header()
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp submit_raw(conn, body) do
    conn
    |> json_header()
    |> post("/api/v1/partner-batches", body)
  end

  defp open(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1",
        "guest_id" => "guest-1",
        "property_id" => "prop-1",
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

  defp pay(operation_id, group_id \\ "g-1", extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => 10_000
      },
      extra
    )
  end

  defp read_group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  defp read_operation(conn, operation_id) do
    conn
    |> get("/api/v1/operations/#{operation_id}")
  end

  describe "identical retries" do
    test "returns the exact original result without reapplying the operation", %{conn: conn} do
      op = open()

      assert %{"results" => [first]} = submit_batch(conn, [op])
      assert %{"results" => [second]} = submit_batch(conn, [op])

      assert second == first

      assert %{"data" => group} = read_group(conn, "g-1")
      assert group["revision"] == 1
      assert Repo.aggregate(Group, :count, :id) == 1
    end

    test "treats object key order as irrelevant", %{conn: conn} do
      plain =
        """
        {"operations":[{"operation_id":"op-1","type":"open_group","occurred_on":"2026-10-03","group_id":"g-1","guest_id":"guest-1","property_id":"prop-1","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"room_id":"room-a","nightly_rate_cents":15000},{"room_id":"room-b","nightly_rate_cents":17500}]}]}
        """

      scrambled =
        """
        {"operations":[{"type":"open_group","rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},{"room_id":"room-b","nightly_rate_cents":17500}],"rate_plan":"flexible","departure_on":"2026-12-13","operation_id":"op-1","occurred_on":"2026-10-03","guest_id":"guest-1","arrival_on":"2026-12-10","property_id":"prop-1","group_id":"g-1"}]}
        """

      first = submit_raw(conn, plain)
      second = submit_raw(conn, scrambled)

      assert json_response(first, 200) == json_response(second, 200)

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(first, 200)

      assert Repo.aggregate(Group, :count, :id) == 1
    end
  end

  describe "payload conflicts" do
    test "rejects a reused operation id with a different payload", %{conn: conn} do
      op = open()

      assert %{"results" => [%{"status" => "applied"}]} = submit_batch(conn, [op])

      assert %{"results" => [conflict]} = submit_batch(conn, [pay("op-1")])

      assert conflict == %{
               "operation_id" => "op-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert %{"data" => %{"deposit_paid_cents" => 0, "revision" => 1}} = read_group(conn, "g-1")
    end

    test "a conflict does not replace the original record", %{conn: conn} do
      op = open()

      assert %{"results" => [applied]} = submit_batch(conn, [op])

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
               submit_batch(conn, [pay("op-1")])

      assert json_response(read_operation(conn, "op-1"), 200) == %{"data" => applied}

      assert %{"results" => [still_conflict]} = submit_batch(conn, [pay("op-1")])
      assert still_conflict["code"] == "operation_id_conflict"
    end

    test "batch processing continues through a conflict", %{conn: conn} do
      op1 = open(%{"operation_id" => "op-1"})
      conflict = pay("op-1")
      op3 = pay("op-3", "g-1")

      assert %{"results" => [first, second, third]} =
               submit_batch(conn, [op1, conflict, op3])

      assert first["status"] == "applied"
      assert second["code"] == "operation_id_conflict"

      assert third == %{
               "operation_id" => "op-3",
               "status" => "applied",
               "group_id" => "g-1",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500,
               "revision" => 2
             }
    end
  end

  describe "remembered rejections" do
    test "a later successful replay returns the original rejection", %{conn: conn} do
      missing_group_payment = pay("op-2", "g-9")

      assert %{"results" => [rejected]} = submit_batch(conn, [missing_group_payment])

      assert rejected == %{
               "operation_id" => "op-2",
               "status" => "rejected",
               "code" => "group_not_found"
             }

      assert %{"results" => [%{"status" => "applied"}]} =
               submit_batch(conn, [open(%{"operation_id" => "op-1", "group_id" => "g-9"})])

      assert %{"results" => [retried]} = submit_batch(conn, [missing_group_payment])
      assert retried == rejected

      assert %{"data" => %{"deposit_paid_cents" => 0, "revision" => 1}} = read_group(conn, "g-9")
    end

    test "a stale-revision rejection is returned verbatim on retry", %{conn: conn} do
      stale = pay("op-2", "g-1", %{"expected_revision" => 5})

      assert %{"results" => [_, first_stale]} = submit_batch(conn, [open(), stale])
      applied_pay = pay("op-3", "g-1")
      assert %{"results" => [%{"revision" => 2}]} = submit_batch(conn, [applied_pay])

      assert %{"results" => [retried_stale]} = submit_batch(conn, [stale])
      assert retried_stale == first_stale

      assert first_stale == %{
               "operation_id" => "op-2",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "g-1",
               "expected_revision" => 5,
               "actual_revision" => 1
             }
    end

    test "retrying stale content with a corrected revision is a conflict", %{conn: conn} do
      stale = pay("op-2", "g-1", %{"expected_revision" => 5})

      assert %{"results" => [_, %{"code" => "stale_revision"}]} =
               submit_batch(conn, [open(), stale])

      corrected = pay("op-2", "g-1", %{"expected_revision" => 1})

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
               submit_batch(conn, [corrected])

      assert %{"data" => %{"deposit_paid_cents" => 0, "revision" => 1}} = read_group(conn, "g-1")
    end
  end

  describe "exact stored results" do
    test "a replay returns the stored revision without consulting current state", %{conn: conn} do
      payment = pay("op-2", "g-1")

      assert %{"results" => [_, applied]} = submit_batch(conn, [open(), payment])
      assert applied["revision"] == 2

      move = %{
        "operation_id" => "op-3",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1",
        "new_arrival_on" => "2026-12-17"
      }

      assert %{"results" => [%{"revision" => 3}]} = submit_batch(conn, [move])

      assert %{"results" => [replayed]} = submit_batch(conn, [payment])
      assert replayed == applied

      assert %{"data" => %{"revision" => 3}} = read_group(conn, "g-1")
    end

    test "a repeated operation inside one batch is replayed, not applied twice", %{conn: conn} do
      op = open()

      assert %{"results" => [first, second]} = submit_batch(conn, [op, op])

      assert first == second
      assert first["status"] == "applied"
      assert Repo.aggregate(Group, :count, :id) == 1

      assert %{"data" => %{"revision" => 1}} = read_group(conn, "g-1")
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result for a remembered operation", %{conn: conn} do
      assert %{"results" => [applied]} = submit_batch(conn, [open()])

      assert json_response(read_operation(conn, "op-1"), 200) == %{"data" => applied}
    end

    test "returns operation_not_found for an unknown identifier", %{conn: conn} do
      conn_response = read_operation(conn, "never-seen")

      assert conn_response.status == 404
      assert json_response(conn_response, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "exposes only the stored result", %{conn: conn} do
      assert %{"results" => [rejected]} =
               submit_batch(conn, [pay("op-2", "g-9")])

      assert json_response(read_operation(conn, "op-2"), 200) == %{"data" => rejected}
    end
  end

  describe "audit records" do
    test "retains type and complete content and preserves commit order", %{conn: conn} do
      payment = pay("op-2", "g-1")

      assert %{"results" => [_, _]} = submit_batch(conn, [open(), payment])

      [open_record, pay_record] = Repo.all(from o in Operation, order_by: o.id)

      assert open_record.id < pay_record.id
      assert open_record.type == "open_group"
      assert pay_record.type == "record_cash_payment"
      assert Jason.decode!(open_record.content) == open()
      assert Jason.decode!(pay_record.content) == payment

      assert Jason.decode!(pay_record.result) == %{
               "operation_id" => "op-2",
               "status" => "applied",
               "group_id" => "g-1",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500,
               "revision" => 2
             }
    end
  end

  describe "concurrent submissions" do
    test "two simultaneous first submissions apply at most once", %{conn: _conn} do
      op = open(%{"operation_id" => "op-race"})

      submit = fn ->
        conn = Phoenix.ConnTest.build_conn() |> json_header()

        conn
        |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => [op]}))
        |> json_response(200)
      end

      owner = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(GroupStay.Repo, owner, self())
            submit.()
          end)
        end

      results = Task.await_many(tasks)

      assert [%{"results" => [first]}, %{"results" => [second]}] = results
      assert first == second
      assert first["status"] == "applied"

      assert Repo.aggregate(Group, :count, :id) == 1
      assert Repo.aggregate(Operation, :count, :id) == 1
    end
  end
end
