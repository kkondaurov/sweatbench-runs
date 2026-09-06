defmodule GroupStayWeb.PartnerBatchIdempotencyTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Operations
  alias GroupStay.Repo

  @booked_on "2026-10-03"

  describe "exact retries of applied operations" do
    test "a retry replays the original result without applying effects twice", %{conn: conn} do
      batch = %{"operations" => [open_op("group-81"), payment_op("op-pay", "group-81", 5_000)]}

      first = conn |> post("/api/v1/partner-batches", batch) |> json_response(200)

      second = conn |> post("/api/v1/partner-batches", batch) |> json_response(200)

      assert first == second

      # the retry changed nothing: one payment, not two
      group = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 5_000
      assert group["revision"] == 2
      assert ledger(conn)["cash_held_cents"] == 5_000
    end

    test "the replayed result is verbatim even after the group has moved on", %{conn: conn} do
      apply_open!(conn, "group-81")
      original = only_result(submit(conn, [payment_op("op-pay", "group-81", 1_000)]))
      submit(conn, [payment_op("op-pay-later", "group-81", 2_000)])

      replay = only_result(submit(conn, [payment_op("op-pay", "group-81", 1_000)]))

      assert replay == original
      assert replay["revision"] == 2

      # current state was neither read nor changed by the replay
      group = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 3_000
      assert group["revision"] == 3
    end

    test "JSON object key order does not matter", %{conn: conn} do
      apply_open!(conn, "group-81")

      body_a = """
      {"operations":[{"occurred_on":"#{@booked_on}","type":"record_cash_payment",\
      "amount_cents":1000,"group_id":"group-81","operation_id":"op-key"}]}\
      """

      body_b = """
      {"operations":[{"operation_id":"op-key","group_id":"group-81",\
      "amount_cents":1000,"type":"record_cash_payment","occurred_on":"#{@booked_on}"}]}\
      """

      first =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", body_a)
        |> json_response(200)

      second =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", body_b)
        |> json_response(200)

      assert first == second
      assert hd(second["results"])["status"] == "applied"
      assert get_group(conn, "group-81")["deposit_paid_cents"] == 1_000
    end

    test "array order remains significant", %{conn: conn} do
      rooms_a_b = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]

      rooms_b_a = Enum.reverse(rooms_a_b)

      first = only_result(submit(conn, [open_op("group-81", rooms: rooms_a_b)]))
      assert first["status"] == "applied"

      result = only_result(submit(conn, [open_op("group-81", rooms: rooms_b_a)]))

      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"

      # the original record stands
      assert only_result(submit(conn, [open_op("group-81", rooms: rooms_a_b)])) == first
    end
  end

  describe "remembered rejections" do
    test "a rejected result is replayed even when it would now succeed", %{conn: conn} do
      apply_open!(conn, "group-81")
      rejected = only_result(submit(conn, [payment_op("op-too-much", "group-81", 19_501)]))
      assert rejected["code"] == "payment_exceeds_outstanding"

      submit(conn, [payment_op("op-full", "group-81", 19_500)])

      replay = only_result(submit(conn, [payment_op("op-too-much", "group-81", 19_501)]))

      assert replay == rejected

      group = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 19_500
      assert group["revision"] == 2
    end

    test "invalid operations are remembered under their identifier", %{conn: conn} do
      op = %{"operation_id" => "op-junk", "type" => "teleport_group", "occurred_on" => @booked_on}

      first = only_result(submit(conn, [op]))
      second = only_result(submit(conn, [op]))

      assert first["code"] == "invalid_operation"
      assert second == first
    end

    test "reusing an identifier with a different payload conflicts and preserves the original",
         %{conn: conn} do
      apply_open!(conn, "group-81")
      original = only_result(submit(conn, [payment_op("op-pay", "group-81", 1_000)]))

      conflict = only_result(submit(conn, [payment_op("op-pay", "group-81", 2_000)]))

      assert conflict == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      group = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 1_000
      assert group["revision"] == 2
      assert ledger(conn)["cash_held_cents"] == 1_000

      # the original payload still replays its stored result
      assert only_result(submit(conn, [payment_op("op-pay", "group-81", 1_000)])) == original
    end

    test "retrying a stale operation with a corrected revision is a different payload", %{
      conn: conn
    } do
      apply_open!(conn, "group-81")
      submit(conn, [payment_op("op-other", "group-81", 1_000)])

      stale =
        payment_op("op-stale", "group-81", 1_000)
        |> Map.put("expected_revision", 1)
        |> then(&(submit(conn, [&1]) |> only_result()))

      assert stale["code"] == "stale_revision"

      corrected =
        payment_op("op-stale", "group-81", 1_000)
        |> Map.put("expected_revision", 2)
        |> then(&(submit(conn, [&1]) |> only_result()))

      assert corrected["status"] == "rejected"
      assert corrected["code"] == "operation_id_conflict"
      assert get_group(conn, "group-81")["revision"] == 2
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "exposes the stored result of an applied operation", %{conn: conn} do
      apply_open!(conn, "group-81")
      result = only_result(submit(conn, [payment_op("op-pay", "group-81", 1_000)]))

      stored =
        conn |> get("/api/v1/operations/op-pay") |> json_response(200) |> Map.fetch!("data")

      assert stored == result
    end

    test "exposes the stored result of a rejected operation", %{conn: conn} do
      apply_open!(conn, "group-81")
      result = only_result(submit(conn, [payment_op("op-bad", "group-81", 999_999)]))

      stored =
        conn |> get("/api/v1/operations/op-bad") |> json_response(200) |> Map.fetch!("data")

      assert stored == result
      assert stored["code"] == "payment_exceeds_outstanding"
    end

    test "returns 404 for an operation that was never received", %{conn: conn} do
      assert conn |> get("/api/v1/operations/missing") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end
  end

  describe "unexpected server faults" do
    test "are not remembered and abort the request instead of being swallowed", %{conn: conn} do
      Repo.query!("DROP TABLE room_allocations")
      Repo.query!("DROP TABLE rooms")
      Repo.query!("DROP TABLE groups")

      assert catch_error(
               post(conn, "/api/v1/partner-batches", %{"operations" => [open_op("group-crash")]})
             )

      assert Operations.get_stored_result("op-open-group-crash") == nil
    end
  end

  # Helpers

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp only_result(response) do
    [result] = response["results"]
    result
  end

  defp apply_open!(conn, group_id) do
    result = only_result(submit(conn, [open_op(group_id)]))
    assert result["status"] == "applied"
    result
  end

  defp open_op(group_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-" <> group_id),
      "type" => "open_group",
      "occurred_on" => @booked_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" =>
        Keyword.get(
          opts,
          :rooms,
          [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
        )
    }
  end

  defp payment_op(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => @booked_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp get_group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end
end
