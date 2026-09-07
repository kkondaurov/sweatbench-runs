defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.PartnerOperations
  alias GroupStay.PartnerOperations.OperationRecord
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  describe "durable operation idempotency" do
    test "replays an applied result exactly without consulting newer group state", %{conn: conn} do
      payment = payment_operation(%{"operation_id" => "pay-original"})

      [opened, original_payment] = post_batch(conn, [open_operation(), payment])

      assert opened["revision"] == 1

      assert original_payment == %{
               "operation_id" => "pay-original",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 18_500,
               "revision" => 2
             }

      [later_payment, replay] =
        post_batch(build_conn(), [
          payment_operation(%{"operation_id" => "pay-later"}),
          payment
        ])

      assert later_payment["revision"] == 3
      assert replay == original_payment

      group = Repo.get!(Group, "group-1")
      assert group.revision == 3
      assert group.deposit_paid_cents == 2_000

      assert get(build_conn(), "/api/v1/operations/pay-original") |> json_response(200) == %{
               "data" => original_payment
             }
    end

    test "remembers rejections even when later state would allow the operation", %{conn: conn} do
      payment = payment_operation(%{"operation_id" => "missing-first"})

      [original_rejection] = post_batch(conn, [payment])
      assert original_rejection["code"] == "group_not_found"

      [opened, replay, conflict] =
        post_batch(build_conn(), [
          open_operation(),
          payment,
          Map.put(payment, "expected_revision", 1)
        ])

      assert opened["status"] == "applied"
      assert replay == original_rejection

      assert conflict == %{
               "operation_id" => "missing-first",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      group = Repo.get!(Group, "group-1")
      assert group.revision == 1
      assert group.deposit_paid_cents == 0

      assert get(build_conn(), "/api/v1/operations/missing-first") |> json_response(200) == %{
               "data" => original_rejection
             }
    end

    test "replays the originally observed stale revision details", %{conn: conn} do
      stale =
        payment_operation(%{
          "operation_id" => "stale-payment",
          "expected_revision" => 1
        })

      [_opened, _payment, original_stale] =
        post_batch(conn, [
          open_operation(),
          payment_operation(%{"operation_id" => "first-payment"}),
          stale
        ])

      assert original_stale == %{
               "operation_id" => "stale-payment",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-1",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      [later_payment, replay, conflict] =
        post_batch(build_conn(), [
          payment_operation(%{"operation_id" => "later-payment"}),
          stale,
          Map.put(stale, "expected_revision", 3)
        ])

      assert later_payment["revision"] == 3
      assert replay == original_stale
      assert conflict["code"] == "operation_id_conflict"

      assert get(build_conn(), "/api/v1/operations/stale-payment") |> json_response(200) == %{
               "data" => original_stale
             }
    end

    test "treats object ordering as irrelevant and array ordering as significant", %{conn: conn} do
      operation = open_operation()
      reordered_object = operation |> Enum.reverse() |> Map.new()
      reversed_rooms = Map.update!(operation, "rooms", &Enum.reverse/1)

      [original] = post_batch(conn, [operation])
      [replay, conflict] = post_batch(build_conn(), [reordered_object, reversed_rooms])

      assert replay == original

      assert conflict == %{
               "operation_id" => "open-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert Repo.aggregate(Group, :count) == 1
      assert Repo.aggregate(OperationRecord, :count) == 1
    end

    test "retains complete submissions, operation types, results, and commit order", %{conn: conn} do
      invalid = %{
        "operation_id" => "invalid-remembered",
        "type" => "future_operation",
        "occurred_on" => "2027-01-01",
        "nested" => %{"preserved" => true},
        "items" => [3, 2, 1]
      }

      [invalid_result, _opened] = post_batch(conn, [invalid, open_operation()])
      assert invalid_result["code"] == "invalid_operation"

      records = Repo.all(from record in OperationRecord, order_by: record.commit_order)

      assert Enum.map(records, & &1.operation_id) == ["invalid-remembered", "open-1"]
      assert Enum.map(records, & &1.operation_type) == ["future_operation", "open_group"]

      assert [first_order, second_order] = Enum.map(records, & &1.commit_order)
      assert second_order > first_order

      assert hd(records).submission == invalid
      assert hd(records).result == invalid_result

      [replay] = post_batch(build_conn(), [invalid])
      assert replay == invalid_result
    end

    test "serializes concurrent retries behind a single durable claim" do
      operation = open_operation(%{"operation_id" => "concurrent-open"})

      results =
        1..8
        |> Task.async_stream(
          fn _attempt -> PartnerOperations.process(operation) end,
          max_concurrency: 8,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.uniq(results) == [
               %{
                 "operation_id" => "concurrent-open",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]

      assert Repo.aggregate(Group, :count) == 1
      assert Repo.aggregate(OperationRecord, :count) == 1
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the usual not-found error", %{conn: conn} do
      assert get(conn, "/api/v1/operations/absent") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
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

  defp payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 1_000
      },
      overrides
    )
  end
end
