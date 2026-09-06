defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Groups.{CashPayment, Group}
  alias GroupStay.Operations.Idempotency
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  @open_group %{
    "operation_id" => "op-1001",
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
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp submit_raw(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  defp results(conn), do: json_response(conn, 200)["results"]

  defp single_result(conn, operations) do
    [result] = conn |> submit(operations) |> results()
    result
  end

  defp open_group(conn, overrides \\ %{}) do
    op = Map.merge(@open_group, overrides)
    result = single_result(conn, [op])
    assert result["status"] == "applied"
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

  defp get_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp records do
    Repo.all(from r in OperationRecord, order_by: [asc: r.id])
  end

  # The same submission as @open_group with its object keys written in a
  # different order.
  defp reordered_open_group_json do
    ~s({"rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},) <>
      ~s({"nightly_rate_cents":17500,"room_id":"room-b"}],) <>
      ~s("rate_plan":"flexible","departure_on":"2026-12-13",) <>
      ~s("arrival_on":"2026-12-10","property_id":"ams-canal",) <>
      ~s("guest_id":"guest-22","group_id":"group-81",) <>
      ~s("occurred_on":"2026-10-03","type":"open_group",) <>
      ~s("operation_id":"op-1001"})
  end

  describe "idempotent retries" do
    test "the first operation for an identifier is processed normally and remembered", %{
      conn: conn
    } do
      result = single_result(conn, [@open_group])
      assert result["status"] == "applied"

      assert [record] = records()
      assert record.operation_id == "op-1001"
      assert record.type == "open_group"
      assert record.payload == @open_group
      assert record.result == result
    end

    test "a retry with an equivalent payload returns the exact original result", %{conn: conn} do
      first = single_result(conn, [@open_group])

      retry = single_result(conn, [@open_group])
      assert retry == first

      # The retry did not re-apply the operation.
      assert get_group(conn, "group-81")["revision"] == 1
      assert length(records()) == 1
    end

    test "a retry of an applied operation does not re-apply its domain changes", %{conn: conn} do
      open_group(conn)
      first = single_result(conn, [payment_op()])
      assert first["status"] == "applied"

      retry = single_result(conn, [payment_op()])
      assert retry == first

      group = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 5000
      assert group["revision"] == 2
    end

    test "object key order is irrelevant", %{conn: conn} do
      first = single_result(conn, [@open_group])

      raw = reordered_open_group_json()
      assert Jason.decode!(raw) == @open_group
      refute raw == Jason.encode!(@open_group)

      [retry] = submit_raw(conn, ~s({"operations":[#{raw}]})) |> results()
      assert retry == first

      assert get_group(conn, "group-81")["revision"] == 1
      assert length(records()) == 1
    end

    test "array order remains significant", %{conn: conn} do
      assert single_result(conn, [@open_group])["status"] == "applied"

      reordered_rooms = Map.update!(@open_group, "rooms", &Enum.reverse/1)

      assert single_result(conn, [reordered_rooms]) == %{
               "operation_id" => "op-1001",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
    end

    test "reusing an identifier with a different payload does not replace the original record", %{
      conn: conn
    } do
      first = single_result(conn, [@open_group])

      conflict = single_result(conn, [%{@open_group | "group_id" => "group-other"}])

      assert conflict == %{
               "operation_id" => "op-1001",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      # The conflicting submission was neither applied nor stored.
      assert conn |> get("/api/v1/groups/group-other") |> json_response(404)
      assert [record] = records()
      assert record.payload == @open_group
      assert record.result == first

      # The original payload still replays and the endpoint still reports the
      # original result.
      assert single_result(conn, [@open_group]) == first

      assert conn |> get("/api/v1/operations/op-1001") |> json_response(200) ==
               %{"data" => first}
    end
  end

  describe "remembered rejections" do
    test "a rejection is replayed even once the operation would be valid", %{conn: conn} do
      rejected = single_result(conn, [payment_op()])

      assert rejected == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "group_not_found"
             }

      open_group(conn)

      assert single_result(conn, [payment_op()]) == rejected

      group = get_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 0
      assert group["revision"] == 1
    end

    test "an invalid operation with an identifier is remembered", %{conn: conn} do
      op = %{
        "operation_id" => "op-mystery",
        "type" => "extend_stay",
        "occurred_on" => "2026-10-03"
      }

      rejected = single_result(conn, [op])
      assert rejected["status"] == "rejected"
      assert rejected["code"] == "invalid_operation"

      assert single_result(conn, [op]) == rejected

      conflict = single_result(conn, [%{op | "type" => "renovate_group"}])
      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"
    end

    test "operations without a usable identifier are not remembered", %{conn: conn} do
      anonymous = Map.delete(payment_op(), "operation_id")

      for _ <- 1..2 do
        result = single_result(conn, [anonymous])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end

      results = submit(conn, ["junk", 42]) |> results()
      assert Enum.map(results, & &1["code"]) == ["invalid_operation", "invalid_operation"]

      assert records() == []
    end

    test "a stale-revision rejection is replayed verbatim without consulting current state", %{
      conn: conn
    } do
      open_group(conn)

      stale_op = payment_op(%{"operation_id" => "op-stale", "expected_revision" => 99})
      rejected = single_result(conn, [stale_op])

      assert rejected == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 99,
               "actual_revision" => 1
             }

      # The group moves on...
      assert single_result(conn, [payment_op(%{"operation_id" => "op-pay-2"})])["revision"] == 2

      # ...but the retry still reports the revision observed originally.
      assert single_result(conn, [stale_op]) == rejected
      assert get_group(conn, "group-81")["revision"] == 2
    end

    test "retrying a stale operation with a corrected expected_revision is a conflict", %{
      conn: conn
    } do
      open_group(conn)

      stale_op = payment_op(%{"operation_id" => "op-stale", "expected_revision" => 99})
      assert single_result(conn, [stale_op])["code"] == "stale_revision"

      corrected = payment_op(%{"operation_id" => "op-stale", "expected_revision" => 1})
      result = single_result(conn, [corrected])
      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"

      # The corrected submission was not applied.
      assert get_group(conn, "group-81")["revision"] == 1
    end
  end

  describe "batch interaction" do
    test "a replayed operation keeps batch processing in order", %{conn: conn} do
      statuses =
        conn |> submit([@open_group, payment_op()]) |> results() |> Enum.map(& &1["status"])

      assert statuses == ~w(applied applied)

      [replayed, next] =
        conn
        |> submit([
          payment_op(),
          payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1000})
        ])
        |> results()

      assert replayed["status"] == "applied"
      assert replayed["revision"] == 2

      assert next["status"] == "applied"
      assert next["revision"] == 3

      assert get_group(conn, "group-81")["deposit_paid_cents"] == 6000
    end

    test "the first occurrence of an identifier within a batch wins", %{conn: conn} do
      [first, replay, conflict] =
        conn
        |> submit([@open_group, @open_group, %{@open_group | "group_id" => "group-other"}])
        |> results()

      assert first["status"] == "applied"
      assert replay == first
      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"

      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "a conflict does not stop later operations", %{conn: conn} do
      open_group(conn)
      assert single_result(conn, [payment_op()])["status"] == "applied"

      [conflict, applied] =
        conn
        |> submit([
          payment_op(%{"amount_cents" => 999}),
          payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1000})
        ])
        |> results()

      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"
      assert applied["status"] == "applied"

      assert get_group(conn, "group-81")["deposit_paid_cents"] == 6000
    end
  end

  describe "audit retention" do
    test "retains every remembered operation's type and content in commit order", %{conn: conn} do
      bad_pay = payment_op(%{"operation_id" => "op-bad", "amount_cents" => 0})
      pay = payment_op()

      move = %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-12"
      }

      [open_result, bad_result, pay_result] =
        conn |> submit([@open_group, bad_pay, pay]) |> results()

      [move_result] = conn |> submit([move]) |> results()

      stored = records()

      assert Enum.map(stored, & &1.operation_id) ==
               ["op-1001", "op-bad", "op-pay", "op-move"]

      assert Enum.map(stored, & &1.type) ==
               ["open_group", "record_cash_payment", "record_cash_payment", "reschedule_group"]

      assert Enum.map(stored, & &1.payload) == [@open_group, bad_pay, pay, move]
      assert Enum.map(stored, & &1.result) == [open_result, bad_result, pay_result, move_result]

      # A conflicting submission adds nothing and replaces nothing.
      assert single_result(conn, [%{@open_group | "group_id" => "group-other"}])["code"] ==
               "operation_id_conflict"

      assert length(records()) == 4
    end
  end

  describe "reading stored results" do
    test "returns the stored result for applied and rejected operations", %{conn: conn} do
      open_group(conn)
      applied = single_result(conn, [payment_op()])

      rejected =
        single_result(conn, [payment_op(%{"operation_id" => "op-pay-2", "group_id" => "nope"})])

      assert conn |> get("/api/v1/operations/op-pay") |> json_response(200) ==
               %{"data" => applied}

      assert conn |> get("/api/v1/operations/op-pay-2") |> json_response(200) ==
               %{"data" => rejected}
    end

    test "exposes only the stored result", %{conn: conn} do
      open_group(conn)

      body = conn |> get("/api/v1/operations/op-1001") |> json_response(200)
      assert Map.keys(body) == ["data"]
    end

    test "returns the partner identifier unchanged", %{conn: conn} do
      op = Map.put(@open_group, "operation_id", "op 1/x")
      result = single_result(conn, [op])

      assert conn |> get("/api/v1/operations/op%201%2Fx") |> json_response(200) ==
               %{"data" => result}
    end

    test "an unknown identifier returns 404 operation_not_found", %{conn: conn} do
      assert conn |> get("/api/v1/operations/op-nobody") |> json_response(404) ==
               %{"error" => %{"code" => "operation_not_found"}}
    end
  end

  describe "fault tolerance" do
    test "an unexpected exception rolls back the operation and is not remembered" do
      payload = %{"operation_id" => "op-boom", "type" => "open_group"}

      assert_raise RuntimeError, "boom", fn ->
        Idempotency.process("op-boom", payload, fn -> raise "boom" end)
      end

      assert records() == []

      # Nothing was remembered, so the identifier can still be processed.
      result =
        Idempotency.process("op-boom", payload, fn ->
          %{"operation_id" => "op-boom", "status" => "applied"}
        end)

      assert result["status"] == "applied"
      assert [%OperationRecord{operation_id: "op-boom"}] = records()
    end

    test "domain changes made before an unexpected exception are rolled back", %{conn: conn} do
      open_group(conn)
      group = Repo.get_by!(Group, group_id: "group-81")

      assert_raise RuntimeError, "boom", fn ->
        Idempotency.process("op-boom", %{"operation_id" => "op-boom"}, fn ->
          Repo.insert!(%CashPayment{
            group_id: group.id,
            amount_cents: 123,
            occurred_on: ~D[2026-10-04],
            operation_id: "op-boom"
          })

          raise "boom"
        end)
      end

      assert Repo.aggregate(CashPayment, :count) == 0
      refute Enum.any?(records(), &(&1.operation_id == "op-boom"))
      assert get_group(conn, "group-81")["revision"] == 1
    end
  end
end
