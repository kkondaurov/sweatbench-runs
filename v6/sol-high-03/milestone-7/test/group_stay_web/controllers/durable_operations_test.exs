defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.{Group, Operations, PartnerOperation, Repo}

  describe "durable partner operation idempotency" do
    test "returns the exact applied result for an equivalent retry without consulting group state",
         %{conn: conn} do
      opening = open_operation("durable-open", "durable-group")

      assert %{"results" => [original]} =
               conn |> post_batch([opening]) |> json_response(200)

      assert original == %{
               "operation_id" => "durable-open",
               "status" => "applied",
               "group_id" => "durable-group",
               "deposit_due_cents" => 6_000,
               "revision" => 1
             }

      payment = payment_operation("later-payment", "durable-group", 1_000, 1)

      assert %{"results" => [%{"revision" => 2}]} =
               build_conn() |> post_batch([payment]) |> json_response(200)

      equivalent =
        opening
        |> Enum.reverse()
        |> Map.new()
        |> Map.update!("rooms", fn rooms ->
          Enum.map(rooms, fn room -> room |> Enum.reverse() |> Map.new() end)
        end)

      assert %{"results" => [^original]} =
               build_conn() |> post_batch([equivalent]) |> json_response(200)

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
               get_group("durable-group")

      assert get(build_conn(), "/api/v1/operations/durable-open") |> json_response(200) == %{
               "data" => original
             }
    end

    test "rejects a changed payload without replacing the original record", %{conn: conn} do
      opening = open_operation("conflict-id", "conflict-group")
      assert %{"results" => [original]} = conn |> post_batch([opening]) |> json_response(200)

      changed = Map.put(opening, "rooms", Enum.reverse(opening["rooms"]))

      assert build_conn() |> post_batch([changed]) |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "conflict-id",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }

      assert get(build_conn(), "/api/v1/operations/conflict-id") |> json_response(200) == %{
               "data" => original
             }

      assert build_conn() |> post_batch([opening]) |> json_response(200) == %{
               "results" => [original]
             }

      assert Repo.aggregate(PartnerOperation, :count) == 1
    end

    test "remembers handled rejections even after domain state changes", %{conn: conn} do
      rejected = payment_operation("rejected-once", "eventual-group", 100, 1)

      assert conn |> post_batch([rejected]) |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "rejected-once",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             }

      setup = [
        open_operation("eventual-open", "eventual-group"),
        payment_operation("eventual-payment", "eventual-group", 50, 1)
      ]

      assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
               build_conn() |> post_batch(setup) |> json_response(200)

      assert build_conn() |> post_batch([rejected]) |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "rejected-once",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             }

      corrected = Map.put(rejected, "expected_revision", 2)

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
               build_conn() |> post_batch([corrected]) |> json_response(200)

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 50}} =
               get_group("eventual-group")
    end

    test "replays the originally observed stale revision verbatim", %{conn: conn} do
      setup = [
        open_operation("stale-open", "stale-group"),
        payment_operation("original-stale", "stale-group", 10, 0),
        payment_operation("advancing-payment", "stale-group", 20, 1)
      ]

      assert %{"results" => [_, stale, %{"revision" => 2}]} =
               conn |> post_batch(setup) |> json_response(200)

      assert stale == %{
               "operation_id" => "original-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "stale-group",
               "expected_revision" => 0,
               "actual_revision" => 1
             }

      assert build_conn() |> post_batch([Enum.at(setup, 1)]) |> json_response(200) == %{
               "results" => [stale]
             }
    end

    test "applies duplicate operations only once within a batch and preserves commit order", %{
      conn: conn
    } do
      first_payment = payment_operation("same-payment", "same-batch-group", 100, 1)

      operations = [
        open_operation("same-batch-open", "same-batch-group"),
        first_payment,
        first_payment,
        payment_operation("following-payment", "same-batch-group", 50, 2),
        %{"operation_id" => "unknown-operation", "type" => "summon_gremlin", "claw" => 7}
      ]

      assert %{"results" => [_, first, retry, following, rejected]} =
               conn |> post_batch(operations) |> json_response(200)

      assert first == retry
      assert first["revision"] == 2
      assert following["revision"] == 3
      assert rejected["code"] == "invalid_operation"

      assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 150}} =
               get_group("same-batch-group")

      records =
        PartnerOperation
        |> order_by(asc: :id)
        |> Repo.all()

      assert Enum.map(records, & &1.operation_id) == [
               "same-batch-open",
               "same-payment",
               "following-payment",
               "unknown-operation"
             ]

      assert Enum.map(records, & &1.operation_type) == [
               "open_group",
               "record_cash_payment",
               "record_cash_payment",
               "summon_gremlin"
             ]

      unknown = List.last(records)
      assert unknown.submitted_payload == List.last(operations)
      assert unknown.result["code"] == "invalid_operation"

      assert get(build_conn(), "/api/v1/operations/unknown-operation") |> json_response(200) ==
               %{"data" => rejected}
    end

    test "serializes concurrent retries with at-most-once effects", %{conn: conn} do
      assert %{"results" => [%{"revision" => 1}]} =
               conn
               |> post_batch([open_operation("concurrent-open", "concurrent-idempotent")])
               |> json_response(200)

      payment = payment_operation("concurrent-same-id", "concurrent-idempotent", 100, 1)

      results =
        [payment, payment]
        |> Task.async_stream(
          fn operation -> Operations.apply_batch([operation]) |> hd() end,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert [first, second] = results
      assert first == second
      assert first.revision == 2

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 100}} =
               get_group("concurrent-idempotent")

      assert Repo.aggregate(
               from(operation in PartnerOperation,
                 where: operation.operation_id == "concurrent-same-id"
               ),
               :count
             ) == 1
    end

    test "returns 500, rolls domain changes back, and stores nothing on an unexpected failure", %{
      conn: conn
    } do
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        CREATE TRIGGER force_partner_operation_failure
        BEFORE INSERT ON partner_operations
        BEGIN
          SELECT RAISE(ABORT, 'forced audit failure');
        END
        """,
        []
      )

      assert_error_sent 500, fn ->
        post_batch(conn, [open_operation("failed-open", "rolled-back-group")])
      end

      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER force_partner_operation_failure", [])

      assert Repo.get(Group, "rolled-back-group") == nil
      assert Operations.get_operation("failed-open") == nil
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the operation-not-found error", %{conn: conn} do
      assert conn |> get("/api/v1/operations/missing") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{"operations" => operations})

  defp get_group(group_id),
    do: build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200)

  defp open_operation(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-durable",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-03",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 5_000}
      ]
    }
  end

  defp payment_operation(operation_id, group_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end
end
