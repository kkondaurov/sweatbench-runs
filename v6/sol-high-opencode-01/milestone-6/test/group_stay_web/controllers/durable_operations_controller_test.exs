defmodule GroupStayWeb.DurableOperationsControllerTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.OperationalCore
  alias GroupStay.OperationalCore.PartnerOperation
  alias GroupStay.Repo

  describe "durable partner operations" do
    test "returns an applied retry verbatim without applying it again", %{conn: conn} do
      payment = payment_operation("pay-once", 1_000, %{"expected_revision" => 1})

      assert %{"results" => [_, original, later, retried]} =
               conn
               |> post_batch([
                 open_operation(),
                 payment,
                 payment_operation("pay-later", 500, %{"expected_revision" => 2}),
                 payment
               ])
               |> json_response(200)

      assert original == %{
               "operation_id" => "pay-once",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 500,
               "revision" => 2
             }

      assert retried == original
      assert later["revision"] == 3

      assert %{
               "data" => %{
                 "revision" => 3,
                 "cash_paid_cents" => 1_500,
                 "outstanding_deposit_cents" => 0
               }
             } = get_group("group-1")

      assert json_response(get(build_conn(), "/api/v1/operations/pay-once"), 200) == %{
               "data" => original
             }
    end

    test "remembers a rejection even after domain state makes the payload valid", %{conn: conn} do
      payment = payment_operation("pay-before-open", 500)

      assert %{"results" => [rejected]} =
               conn |> post_batch([payment]) |> json_response(200)

      assert rejected == %{
               "operation_id" => "pay-before-open",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-1"
             }

      assert %{"results" => [%{"status" => "applied"}]} =
               build_conn() |> post_batch([open_operation()]) |> json_response(200)

      assert %{"results" => [retried]} =
               build_conn() |> post_batch([payment]) |> json_response(200)

      assert retried == rejected

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
               get_group("group-1")
    end

    test "returns the originally observed stale revision after later changes", %{conn: conn} do
      stale = payment_operation("stale", 100, %{"expected_revision" => 1})

      assert %{"results" => [_, _, original_stale]} =
               conn
               |> post_batch([
                 open_operation(),
                 payment_operation("first-payment", 100),
                 stale
               ])
               |> json_response(200)

      assert original_stale["code"] == "stale_revision"
      assert original_stale["actual_revision"] == 2

      assert %{"results" => [%{"revision" => 3}]} =
               build_conn()
               |> post_batch([payment_operation("second-payment", 100)])
               |> json_response(200)

      assert %{"results" => [retried]} =
               build_conn() |> post_batch([stale]) |> json_response(200)

      assert retried == original_stale
    end

    test "rejects a changed payload without replacing the stored operation", %{conn: conn} do
      original = open_operation()
      changed = put_in(original, ["rooms"], Enum.reverse(original["rooms"]))

      assert %{"results" => [applied]} =
               conn |> post_batch([original]) |> json_response(200)

      assert %{"results" => [conflict]} =
               build_conn() |> post_batch([changed]) |> json_response(200)

      assert conflict == %{
               "operation_id" => "open-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert json_response(get(build_conn(), "/api/v1/operations/open-1"), 200) == %{
               "data" => applied
             }

      assert %{"data" => %{"rooms" => [%{"room_id" => "room-a"}, %{"room_id" => "room-b"}]}} =
               get_group("group-1")

      assert Repo.aggregate(PartnerOperation, :count) == 1
    end

    test "treats integer and floating-point JSON values as different payloads", %{conn: conn} do
      payment = payment_operation("numeric-value", 100)

      assert %{"results" => [_, %{"status" => "applied"}]} =
               conn |> post_batch([open_operation(), payment]) |> json_response(200)

      assert %{
               "results" => [
                 %{
                   "operation_id" => "numeric-value",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } =
               build_conn()
               |> post_batch([%{payment | "amount_cents" => 100.0}])
               |> json_response(200)

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 100}} =
               get_group("group-1")
    end

    test "retains complete submissions, operation types, and first-commit order", %{conn: conn} do
      invalid = %{
        "operation_id" => "invalid-1",
        "type" => "unknown_type",
        "occurred_on" => "2027-01-01",
        "nested" => %{"values" => [3, 2, 1], "present" => nil}
      }

      operations = [invalid, open_operation()]

      assert %{"results" => [%{"status" => "rejected"}, %{"status" => "applied"}]} =
               conn |> post_batch(operations) |> json_response(200)

      stored =
        from(operation in PartnerOperation, order_by: operation.id)
        |> Repo.all()

      assert Enum.map(stored, & &1.operation_id) == ["invalid-1", "open-1"]
      assert Enum.map(stored, & &1.operation_type) == ["unknown_type", "open_group"]
      assert Enum.map(stored, & &1.submission) == operations
    end

    test "serializes concurrent retries to one domain effect", %{conn: conn} do
      assert %{"results" => [%{"status" => "applied"}]} =
               conn |> post_batch([open_operation()]) |> json_response(200)

      payment = payment_operation("concurrent-payment", 250, %{"expected_revision" => 1})

      results =
        1..8
        |> Task.async_stream(
          fn _ -> OperationalCore.process_batch([payment]) end,
          max_concurrency: 8,
          ordered: false
        )
        |> Enum.map(fn {:ok, [result]} -> result end)

      assert Enum.uniq(results) == [
               %{
                 "operation_id" => "concurrent-payment",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "amount_cents" => 250,
                 "outstanding_deposit_cents" => 1_250,
                 "revision" => 2
               }
             ]

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 250}} =
               get_group("group-1")
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stable missing-operation error", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/operations/absent"), 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end
  end

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  defp get_group(group_id) do
    build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200)
  end

  defp open_operation do
    %{
      "operation_id" => "open-1",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "group-1",
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-12-10",
      "departure_on" => "2027-12-11",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 5_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 2_500}
      ]
    }
  end

  defp payment_operation(operation_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-02",
        "group_id" => "group-1",
        "amount_cents" => amount
      },
      overrides
    )
  end
end
