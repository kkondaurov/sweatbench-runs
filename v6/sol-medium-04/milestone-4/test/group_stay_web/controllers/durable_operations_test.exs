defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.{OperationRecord, Operations, Repo}

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-durable",
        "type" => "open_group",
        "occurred_on" => "2027-02-01",
        "group_id" => "durable-group",
        "guest_id" => "durable-guest",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-03",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 12_000}
        ]
      },
      overrides
    )
  end

  defp submit(operations) do
    build_conn()
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "an equivalent retry returns the original result without applying again" do
    operation = open_operation()

    [first, retry] = submit([operation, Map.new(Enum.reverse(Map.to_list(operation)))])

    assert retry == first
    assert first["revision"] == 1

    [payment] =
      submit([
        %{
          "operation_id" => "pay-after-open",
          "type" => "record_cash_payment",
          "occurred_on" => "2027-02-02",
          "group_id" => "durable-group",
          "amount_cents" => 1_000
        }
      ])

    assert payment["revision"] == 2
    assert submit([operation]) == [first]

    group =
      get(build_conn(), ~p"/api/v1/groups/durable-group")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group["revision"] == 2
    assert group["cash_paid_cents"] == 1_000

    assert get(build_conn(), ~p"/api/v1/operations/open-durable") |> json_response(200) == %{
             "data" => first
           }
  end

  test "concurrent retries have at-most-once domain effects" do
    operation = open_operation()

    results =
      1..8
      |> Task.async_stream(
        fn _ -> Operations.process_batch([operation]) end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    json_results = Enum.map(results, &(Jason.encode!(&1) |> Jason.decode!()))

    assert length(Enum.uniq(json_results)) == 1
    assert hd(json_results)["revision"] == 1
    assert Repo.aggregate(OperationRecord, :count) == 1

    group = Operations.get_group("durable-group")
    assert group.revision == 1
  end

  test "rejected operations are remembered with their original state observations" do
    stale = %{
      "operation_id" => "remembered-stale",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-02-03",
      "group_id" => "durable-group",
      "amount_cents" => 100,
      "expected_revision" => 1
    }

    [_, payment, first_rejection] =
      submit([
        open_operation(),
        %{
          "operation_id" => "initial-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "2027-02-02",
          "group_id" => "durable-group",
          "amount_cents" => 100
        },
        stale
      ])

    assert payment["revision"] == 2

    assert first_rejection == %{
             "operation_id" => "remembered-stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "durable-group",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    [later_payment] =
      submit([
        %{
          "operation_id" => "later-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "2027-02-04",
          "group_id" => "durable-group",
          "amount_cents" => 100,
          "expected_revision" => 2
        }
      ])

    assert later_payment["revision"] == 3
    assert submit([stale]) == [first_rejection]

    corrected = Map.put(stale, "expected_revision", 3)

    assert submit([corrected]) == [
             %{
               "operation_id" => "remembered-stale",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
           ]

    assert get(build_conn(), ~p"/api/v1/operations/remembered-stale") |> json_response(200) == %{
             "data" => first_rejection
           }
  end

  test "conflicting payloads do not replace the original record and array order is significant" do
    original = open_operation()
    [first] = submit([original])

    reordered_rooms = Map.update!(original, "rooms", &Enum.reverse/1)

    assert [%{"code" => "operation_id_conflict"}] = submit([reordered_rooms])
    assert [%{"code" => "operation_id_conflict"}] = submit([Map.put(original, "extra", true)])

    assert get(build_conn(), ~p"/api/v1/operations/open-durable") |> json_response(200) == %{
             "data" => first
           }

    rooms =
      get(build_conn(), ~p"/api/v1/groups/durable-group")
      |> json_response(200)
      |> get_in(["data", "rooms"])

    assert Enum.map(rooms, &Map.take(&1, ["room_id", "nightly_rate_cents"])) == original["rooms"]
  end

  test "the audit record retains complete submissions and first-commit order" do
    invalid = %{
      "operation_id" => "invalid-audit",
      "type" => "feed_gremlin",
      "nested" => %{"b" => 2, "a" => [1, %{"kept" => true}]}
    }

    submit([invalid, open_operation()])
    submit([invalid])

    records = Repo.all(from record in OperationRecord, order_by: record.id)

    assert Enum.map(records, &{&1.operation_id, &1.operation_type}) == [
             {"invalid-audit", "feed_gremlin"},
             {"open-durable", "open_group"}
           ]

    assert hd(records).submission == invalid
    assert hd(records).result["code"] == "invalid_operation"
  end

  test "an unknown operation is readable and an unknown identifier returns the usual 404" do
    [rejected] =
      submit([%{"operation_id" => "unknown-readable", "type" => "feed_gremlin"}])

    assert get(build_conn(), ~p"/api/v1/operations/unknown-readable") |> json_response(200) == %{
             "data" => rejected
           }

    assert get(build_conn(), ~p"/api/v1/operations/not-recorded") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end
end
