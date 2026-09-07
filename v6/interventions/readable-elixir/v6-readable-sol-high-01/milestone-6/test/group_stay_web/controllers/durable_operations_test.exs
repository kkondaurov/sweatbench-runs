defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.PartnerOperations.OperationRecord
  alias GroupStay.Repo

  describe "durable operation idempotency" do
    test "replays an applied result without applying the operation again", %{conn: conn} do
      operation = open_operation()

      first_result = submit_one(conn, operation)
      assert submit_one(conn, operation) == first_result

      payment = payment_operation()
      payment_result = submit_one(conn, payment)
      assert submit_one(conn, payment) == payment_result

      assert get_group(conn)["revision"] == 2
      assert get_group(conn)["cash_paid_cents"] == 1_000
      assert Repo.aggregate(OperationRecord, :count) == 2
    end

    test "replays a rejection after domain state changes", %{conn: conn} do
      operation = payment_operation(%{"operation_id" => "early-payment"})

      assert submit_one(conn, operation) == %{
               "operation_id" => "early-payment",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-81"
             }

      submit_one(conn, open_operation())

      assert submit_one(conn, operation)["code"] == "group_not_found"
      assert get_group(conn)["revision"] == 1
      assert get_group(conn)["cash_paid_cents"] == 0
    end

    test "preserves stale-revision details from the original attempt", %{conn: conn} do
      submit_one(conn, open_operation())

      stale =
        payment_operation(%{
          "operation_id" => "stale-payment",
          "expected_revision" => 9
        })

      original = submit_one(conn, stale)
      assert original["actual_revision"] == 1

      submit_one(conn, payment_operation())

      assert submit_one(conn, stale) == original
      assert get_group(conn)["revision"] == 2
    end

    test "rejects a changed payload and keeps the original result", %{conn: conn} do
      operation = open_operation()
      original = submit_one(conn, operation)

      conflict =
        submit_one(conn, put_in(operation, ["rooms", Access.at(0), "nightly_rate_cents"], 99))

      assert conflict == %{
               "operation_id" => "open-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert get(conn, "/api/v1/operations/open-1") |> json_response(200) == %{
               "data" => original
             }

      assert get_group(conn)["lodging_total_cents"] == 10_000
      assert Repo.aggregate(OperationRecord, :count) == 1
    end

    test "treats object ordering as irrelevant and array ordering as significant", %{conn: conn} do
      operation = open_operation()
      reordered_object = Map.new(Enum.reverse(Enum.to_list(operation)))

      assert submit_one(conn, reordered_object) == submit_one(conn, operation)

      reversed_rooms =
        open_operation(%{
          "operation_id" => "ordered-rooms",
          "group_id" => "ordered-group",
          "rooms" => [
            %{"room_id" => "one", "nightly_rate_cents" => 1_000},
            %{"room_id" => "two", "nightly_rate_cents" => 2_000}
          ]
        })

      assert submit_one(conn, reversed_rooms)["status"] == "applied"

      reversed_rooms = Map.update!(reversed_rooms, "rooms", &Enum.reverse/1)
      assert submit_one(conn, reversed_rooms)["code"] == "operation_id_conflict"
    end

    test "a corrected expected revision conflicts with the remembered rejection", %{conn: conn} do
      submit_one(conn, open_operation())

      stale = payment_operation(%{"expected_revision" => 8})
      assert submit_one(conn, stale)["code"] == "stale_revision"

      corrected = Map.put(stale, "expected_revision", 1)
      assert submit_one(conn, corrected)["code"] == "operation_id_conflict"
      assert get_group(conn)["revision"] == 1
    end

    test "an unexpected persistence failure rolls back domain changes and is not remembered", %{
      conn: conn
    } do
      Ecto.Adapters.SQL.query!(Repo, """
      CREATE TRIGGER fail_operation_record
      BEFORE INSERT ON partner_operation_records
      BEGIN
        SELECT RAISE(ABORT, 'forced operation-record failure');
      END
      """)

      assert_raise Exqlite.Error, fn -> submit_one(conn, open_operation()) end

      assert Repo.aggregate(OperationRecord, :count) == 0

      assert get(conn, "/api/v1/groups/group-81") |> json_response(404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end
  end

  describe "operation audit records" do
    test "retains complete submissions, results, types, and first-commit order", %{conn: conn} do
      open =
        Map.put(open_operation(), "gateway_metadata", %{"attempt" => 1, "tags" => ["a", "b"]})

      invalid = %{"operation_id" => "invalid-1", "type" => "unknown", "raw" => [2, 1]}

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => [open, invalid]})
      [open_result, invalid_result] = json_response(conn, 200)["results"]

      assert [open_record, invalid_record] =
               OperationRecord |> order_by(asc: :commit_order) |> Repo.all()

      assert open_record.operation_type == "open_group"
      assert open_record.submission == open
      assert open_record.result == open_result
      assert invalid_record.operation_type == "unknown"
      assert invalid_record.submission == invalid
      assert invalid_record.result == invalid_result
      assert open_record.commit_order < invalid_record.commit_order
    end

    test "returns a stable not-found response", %{conn: conn} do
      assert get(conn, "/api/v1/operations/missing") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end
  end

  defp submit_one(conn, operation) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => [operation]})
    |> json_response(200)
    |> get_in(["results", Access.at(0)])
  end

  defp get_group(conn) do
    conn
    |> get("/api/v1/groups/group-81")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp payment_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      overrides
    )
  end
end
