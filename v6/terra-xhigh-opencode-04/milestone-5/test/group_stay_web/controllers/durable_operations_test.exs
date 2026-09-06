defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations
  alias GroupStay.Reservations.Operation

  test "replays an equivalent operation exactly without changing current state", %{conn: conn} do
    operation = open_group("open-1", "group-1")

    [first_result, repeated_result] = submit(conn, [operation, operation])["results"]

    assert first_result == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-1",
             "deposit_due_cents" => 2_000,
             "revision" => 1
           }

    assert repeated_result == first_result

    assert submit(conn, [cash_payment("pay-1", "group-1", 100, 1)])["results"] |> hd() == %{
             "operation_id" => "pay-1",
             "status" => "applied",
             "group_id" => "group-1",
             "amount_cents" => 100,
             "outstanding_deposit_cents" => 1_900,
             "revision" => 2
           }

    # Elixir maps, like JSON objects, do not preserve key order.
    equivalent_operation =
      %{}
      |> Map.put("rooms", [%{"nightly_rate_cents" => 10_000, "room_id" => "group-1-room"}])
      |> Map.put("rate_plan", "flexible")
      |> Map.put("departure_on", "2027-03-02")
      |> Map.put("arrival_on", "2027-03-01")
      |> Map.put("property_id", "ams-canal")
      |> Map.put("guest_id", "guest-22")
      |> Map.put("group_id", "group-1")
      |> Map.put("occurred_on", "2027-01-01")
      |> Map.put("type", "open_group")
      |> Map.put("operation_id", "open-1")

    assert equivalent_operation === operation
    assert submit(conn, [equivalent_operation]) == %{"results" => [first_result]}

    assert conn
           |> get(~p"/api/v1/groups/group-1")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2

    assert conn |> get(~p"/api/v1/operations/open-1") |> json_response(200) == %{
             "data" => first_result
           }
  end

  test "rejects conflicting identifier reuse without replacing its audit record", %{conn: conn} do
    operation =
      open_group("open-1", "group-1")
      |> Map.put("rooms", [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 12_000}
      ])

    first_result = submit(conn, [operation]) |> get_in(["results", Access.at(0)])

    conflicting_operation = Map.put(operation, "rooms", Enum.reverse(operation["rooms"]))

    assert submit(conn, [conflicting_operation]) == %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }

    assert Repo.aggregate(Operation, :count) == 1

    assert conn |> get(~p"/api/v1/operations/open-1") |> json_response(200) == %{
             "data" => first_result
           }
  end

  test "coalesces concurrent retries to one domain effect" do
    operation = open_group("open-1", "group-1")

    results =
      1..8
      |> Task.async_stream(
        fn _ -> Reservations.submit_batch([operation]) end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert Enum.uniq(results) == [
             %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-1",
               "deposit_due_cents" => 2_000,
               "revision" => 1
             }
           ]

    assert Repo.get_by!(Operation, operation_id: "open-1").result == hd(results)
    assert Repo.aggregate(Operation, :count) == 1
  end

  test "remembers handled rejections after the domain state changes", %{conn: conn} do
    rejected_payment = cash_payment("missing-payment", "group-1", 100, 1)

    assert submit(conn, [rejected_payment]) == %{
             "results" => [
               %{
                 "operation_id" => "missing-payment",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ]
           }

    assert submit(conn, [open_group("open-1", "group-1")])["results"]
           |> hd()
           |> Map.fetch!("revision") ==
             1

    assert submit(conn, [rejected_payment])["results"] |> hd() == %{
             "operation_id" => "missing-payment",
             "status" => "rejected",
             "code" => "group_not_found"
           }

    assert conn
           |> get(~p"/api/v1/groups/group-1")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 1

    assert Repo.get_by!(Operation, operation_id: "missing-payment").result == %{
             "operation_id" => "missing-payment",
             "status" => "rejected",
             "code" => "group_not_found"
           }
  end

  test "replays stale revision details and rejects corrected retries as conflicts", %{conn: conn} do
    stale_payment = cash_payment("stale-payment", "group-1", 100, 1)

    response =
      submit(conn, [
        open_group("open-1", "group-1"),
        cash_payment("pay-1", "group-1", 100, 1),
        stale_payment,
        cash_payment("pay-2", "group-1", 100, 2)
      ])

    stale_result = Enum.at(response["results"], 2)

    assert stale_result == %{
             "operation_id" => "stale-payment",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-1",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert submit(conn, [stale_payment]) == %{"results" => [stale_result]}

    assert submit(conn, [Map.put(stale_payment, "expected_revision", 3)]) == %{
             "results" => [
               %{
                 "operation_id" => "stale-payment",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }
  end

  test "retains submitted content, type, result, and commit order for every remembered operation",
       %{
         conn: conn
       } do
    unknown_operation = %{
      "operation_id" => "unknown-1",
      "type" => "future_operation",
      "occurred_on" => "2027-01-01",
      "submitted_by" => %{"gateway" => "partner-a", "attempt" => 1}
    }

    open_operation = open_group("open-1", "group-1")
    response = submit(conn, [unknown_operation, open_operation])

    operations = Repo.all(from operation in Operation, order_by: [asc: operation.id])

    assert Enum.map(operations, & &1.operation_id) == ["unknown-1", "open-1"]
    assert Enum.map(operations, & &1.operation_type) == ["future_operation", "open_group"]
    assert Enum.map(operations, & &1.submitted_payload) == [unknown_operation, open_operation]
    assert Enum.map(operations, & &1.result) == response["results"]
    assert Enum.map(operations, & &1.id) == Enum.sort(Enum.map(operations, & &1.id))
  end

  test "returns the documented error for an unknown operation identifier", %{conn: conn} do
    assert conn |> get(~p"/api/v1/operations/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp open_group(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-03-01",
      "departure_on" => "2027-03-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "#{group_id}-room", "nightly_rate_cents" => 10_000}]
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents, expected_revision) do
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
