defmodule GroupStayWeb.OperationControllerTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Groups
  alias GroupStay.Groups.PartnerOperation
  alias GroupStay.Repo

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp post_raw_batch(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-durable",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: "durable-group",
        guest_id: "guest-durable",
        property_id: "ams-canal",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-12",
        rate_plan: "flexible",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 100},
          %{room_id: "room-b", nightly_rate_cents: 200}
        ]
      },
      overrides
    )
  end

  test "retries return the original result and object key order does not matter", %{conn: conn} do
    first_result =
      conn
      |> post_batch([open_operation()])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert first_result == %{
             "operation_id" => "open-durable",
             "status" => "applied",
             "group_id" => "durable-group",
             "deposit_due_cents" => 120,
             "revision" => 1
           }

    payment_result =
      conn
      |> post_batch([
        %{
          operation_id: "pay-durable",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "durable-group",
          amount_cents: 10
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert payment_result["revision"] == 2

    reordered_payload =
      ~s({"operations":[{"type":"open_group","operation_id":"open-durable","occurred_on":"2026-10-03","group_id":"durable-group","guest_id":"guest-durable","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-12","rate_plan":"flexible","rooms":[{"nightly_rate_cents":100,"room_id":"room-a"},{"nightly_rate_cents":200,"room_id":"room-b"}]}]})

    assert conn
           |> post_raw_batch(reordered_payload)
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == first_result

    assert conn
           |> get("/api/v1/groups/durable-group")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2

    assert conn
           |> get("/api/v1/operations/open-durable")
           |> json_response(200) == %{"data" => first_result}

    stored = Repo.get_by!(PartnerOperation, operation_id: "open-durable")
    assert stored.operation_type == "open_group"

    assert stored.submitted_content["rooms"] == [
             %{"room_id" => "room-a", "nightly_rate_cents" => 100},
             %{"room_id" => "room-b", "nightly_rate_cents" => 200}
           ]

    reordered_rooms = open_operation(%{rooms: Enum.reverse(open_operation().rooms)})

    assert conn
           |> post_batch([reordered_rooms])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == %{
             "operation_id" => "open-durable",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert conn
           |> get("/api/v1/operations/open-durable")
           |> json_response(200) == %{"data" => first_result}
  end

  test "remembers handled rejections after the domain state changes", %{conn: conn} do
    failed_payment = %{
      operation_id: "payment-before-open",
      type: "record_cash_payment",
      occurred_on: "2026-10-04",
      group_id: "created-later",
      amount_cents: 1
    }

    original_rejection =
      conn
      |> post_batch([failed_payment])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert original_rejection == %{
             "operation_id" => "payment-before-open",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "created-later"
           }

    assert conn
           |> post_batch([open_operation(%{group_id: "created-later"})])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "status"]) == "applied"

    assert conn
           |> post_batch([failed_payment])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == original_rejection

    group =
      conn
      |> get("/api/v1/groups/created-later")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["revision"] == 1
    assert group["deposit_paid_cents"] == 0

    assert conn
           |> get("/api/v1/operations/payment-before-open")
           |> json_response(200) == %{"data" => original_rejection}
  end

  test "stale revision details remain stable and corrected payloads conflict", %{conn: conn} do
    results =
      conn
      |> post_batch([
        open_operation(),
        %{
          operation_id: "pay-for-stale",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "durable-group",
          amount_cents: 10
        }
      ])
      |> json_response(200)

    assert Enum.map(results["results"], & &1["status"]) == ["applied", "applied"]

    stale_operation = %{
      operation_id: "stale-durable",
      type: "record_cash_payment",
      occurred_on: "2026-10-05",
      group_id: "durable-group",
      amount_cents: 1,
      expected_revision: 1
    }

    original_stale =
      conn
      |> post_batch([stale_operation])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert original_stale["code"] == "stale_revision"
    assert original_stale["actual_revision"] == 2

    assert conn
           |> post_batch([
             %{
               operation_id: "move-after-stale",
               type: "reschedule_group",
               occurred_on: "2026-10-06",
               group_id: "durable-group",
               new_arrival_on: "2026-12-20"
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "revision"]) == 3

    assert conn
           |> post_batch([stale_operation])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == original_stale

    assert conn
           |> post_batch([%{stale_operation | expected_revision: 2}])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == %{
             "operation_id" => "stale-durable",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }
  end

  test "concurrent identical submissions apply a group only once" do
    operation =
      open_operation(%{operation_id: "concurrent-open"})
      |> Jason.encode!()
      |> Jason.decode!()

    results =
      1..6
      |> Task.async_stream(fn _ -> Groups.process_batch([operation]) end,
        max_concurrency: 6,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert Enum.uniq(results) == [
             %{
               "operation_id" => "concurrent-open",
               "status" => "applied",
               "group_id" => "durable-group",
               "deposit_due_cents" => 120,
               "revision" => 1
             }
           ]

    assert Repo.aggregate(PartnerOperation, :count) == 1
    assert Groups.get_group("durable-group").revision == 1
  end

  test "returns the operation lookup not found error", %{conn: conn} do
    assert conn
           |> get("/api/v1/operations/missing-operation")
           |> json_response(404) == %{"error" => %{"code" => "operation_not_found"}}
  end
end
