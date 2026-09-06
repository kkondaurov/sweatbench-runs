defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: true

  @moduletag :capture_log

  alias GroupStay.Operations
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  import Ecto.Query

  describe "retrying an applied operation" do
    test "replays the exact original result without applying effects again" do
      run_and_get_results([
        open_operation(%{"operation_id" => "op-open", "group_id" => "group-retry"}),
        pay_operation("group-retry", 10_000, %{"operation_id" => "op-pay"})
      ])

      results =
        run_and_get_results([pay_operation("group-retry", 10_000, %{"operation_id" => "op-pay"})])

      assert results == [
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-retry",
                 "amount_cents" => 10_000,
                 "outstanding_deposit_cents" => 9_500,
                 "revision" => 2
               }
             ]

      assert fetch_group("group-retry")["revision"] == 2
      assert fetch_group("group-retry")["cash_paid_cents"] == 10_000
      assert fetch_ledger()["cash_held_cents"] == 10_000
    end

    test "ignores object key order while treating array order as significant" do
      apply_json =
        ~s({"operations":[{"type":"open_group","occurred_on":"2026-10-03","operation_id":"op-keys","group_id":"group-keys","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"room_id":"room-a","nightly_rate_cents":15000},{"room_id":"room-b","nightly_rate_cents":17500}]}]})

      retry_nested_key_order =
        ~s({"operations":[{"rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},{"nightly_rate_cents":17500,"room_id":"room-b"}],"rate_plan":"flexible","departure_on":"2026-12-13","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22","group_id":"group-keys","occurred_on":"2026-10-03","operation_id":"op-keys","type":"open_group"}]})

      retry_room_array_reordered =
        ~s({"operations":[{"type":"open_group","occurred_on":"2026-10-03","operation_id":"op-keys","group_id":"group-keys","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"room_id":"room-b","nightly_rate_cents":17500},{"room_id":"room-a","nightly_rate_cents":15000}]}]})

      first = post_raw_body(apply_json) |> json_response(200) |> Map.fetch!("results")

      replay =
        post_raw_body(retry_nested_key_order) |> json_response(200) |> Map.fetch!("results")

      assert first == [
               %{
                 "operation_id" => "op-keys",
                 "status" => "applied",
                 "group_id" => "group-keys",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]

      assert replay == first

      conflict_results =
        post_raw_body(retry_room_array_reordered) |> json_response(200) |> Map.fetch!("results")

      assert conflict_results == [
               %{
                 "operation_id" => "op-keys",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
    end

    test "a repeated operation inside one batch has at-most-once effects" do
      results =
        run_and_get_results([
          open_operation(%{"operation_id" => "op-open", "group_id" => "group-twice"}),
          pay_operation("group-twice", 5_000, %{"operation_id" => "op-pay"}),
          pay_operation("group-twice", 5_000, %{"operation_id" => "op-pay"})
        ])

      assert [%{"revision" => 1}, %{"revision" => 2}, second_pay] = results
      assert second_pay["revision"] == 2
      assert second_pay["outstanding_deposit_cents"] == 14_500
      assert fetch_group("group-twice")["cash_paid_cents"] == 5_000
    end
  end

  describe "retrying a rejected operation" do
    test "replays the original rejection even when the operation would now be valid" do
      run_and_get_results([
        open_operation(%{"operation_id" => "op-open", "group_id" => "group-late"})
      ])

      too_early = credit_operation("group-late", 1_000, %{"operation_id" => "op-credit-1"})

      assert run_and_get_results([too_early]) == [
               %{
                 "operation_id" => "op-credit-1",
                 "status" => "rejected",
                 "code" => "insufficient_credit"
               }
             ]

      # Fund the group, convert a refundable cancellation into credit, which would
      # cover the previously rejected application.
      run_and_get_results([
        pay_operation("group-late", 19_500, %{"operation_id" => "op-fund"}),
        cancel_operation("group-late", %{
          "operation_id" => "op-cancel",
          "refund_method" => "hotel_credit"
        })
      ])

      assert fetch_credit("guest-22")["available_cents"] >= 1_000

      assert run_and_get_results([too_early]) == [
               %{
                 "operation_id" => "op-credit-1",
                 "status" => "rejected",
                 "code" => "insufficient_credit"
               }
             ]
    end

    test "a stale revision retry returns the originally observed revision verbatim" do
      run_and_get_results([
        open_operation(%{"operation_id" => "op-open", "group_id" => "group-stale"}),
        pay_operation("group-stale", 1_000, %{"operation_id" => "op-fund"})
      ])

      stale =
        reschedule_operation("group-stale", "2027-01-05", %{
          "operation_id" => "op-move",
          "expected_revision" => 1
        })

      assert run_and_get_results([stale]) == [
               %{
                 "operation_id" => "op-move",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-stale",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]

      run_and_get_results([pay_operation("group-stale", 1_000, %{"operation_id" => "op-more"})])
      assert fetch_group("group-stale")["revision"] == 3

      assert hd(run_and_get_results([stale]))["actual_revision"] == 2

      corrected =
        reschedule_operation("group-stale", "2027-01-05", %{
          "operation_id" => "op-move",
          "expected_revision" => 2
        })

      assert hd(run_and_get_results([corrected]))["code"] == "operation_id_conflict"
    end
  end

  describe "identifier reuse with a different payload" do
    test "rejects with operation_id_conflict and preserves the original record" do
      run_and_get_results([
        open_operation(%{"operation_id" => "op-open", "group_id" => "group-conflict"}),
        pay_operation("group-conflict", 100, %{"operation_id" => "op-shared"})
      ])

      results =
        run_and_get_results([
          pay_operation("group-conflict", 200, %{"operation_id" => "op-shared"})
        ])

      assert results == [
               %{
                 "operation_id" => "op-shared",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]

      assert fetch_group("group-conflict")["cash_paid_cents"] == 100

      assert hd(
               run_and_get_results([
                 pay_operation("group-conflict", 100, %{"operation_id" => "op-shared"})
               ])
             )["status"] == "applied"

      assert fetch_group("group-conflict")["cash_paid_cents"] == 100
    end

    test "conflicts neither stop the batch nor replace the stored submission" do
      run_and_get_results([
        open_operation(%{"operation_id" => "op-open", "group_id" => "group-batch-conflict"})
      ])

      results =
        run_and_get_results([
          pay_operation("group-batch-conflict", 100, %{"operation_id" => "op-one"}),
          pay_operation("group-batch-conflict", 999_999, %{"operation_id" => "op-one"}),
          pay_operation("group-batch-conflict", 100, %{"operation_id" => "op-two"})
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "rejected", "applied"]
      assert Enum.at(results, 1)["code"] == "operation_id_conflict"
      assert fetch_group("group-batch-conflict")["cash_paid_cents"] == 200
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "exposes the stored result for applied and remembered operations" do
      run_and_get_results([
        open_operation(%{"operation_id" => "op-open", "group_id" => "group-read"}),
        pay_operation("group-read", 500, %{"operation_id" => "op-read"})
      ])

      applied =
        build_conn()
        |> get("/api/v1/operations/op-read")
        |> json_response(200)
        |> Map.fetch!("data")

      assert applied["status"] == "applied"
      assert applied["group_id"] == "group-read"
      assert applied["revision"] == 2
    end

    test "exposes the stored result for rejected operations" do
      run_and_get_results([pay_operation("missing-group", 100, %{"operation_id" => "op-miss"})])

      rejected =
        build_conn()
        |> get("/api/v1/operations/op-miss")
        |> json_response(200)
        |> Map.fetch!("data")

      assert rejected == %{
               "operation_id" => "op-miss",
               "status" => "rejected",
               "code" => "group_not_found"
             }
    end

    test "returns 404 operation_not_found for unknown identifiers" do
      conn = build_conn() |> get("/api/v1/operations/never-seen")

      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end
  end

  describe "durable audit records" do
    test "retain type, complete submitted content, and commit order" do
      operations = [
        open_operation(%{"operation_id" => "op-audit-open", "group_id" => "group-audit"}),
        pay_operation("group-audit", 250, %{"operation_id" => "op-audit-pay"}),
        pay_operation("group-audit", 999_999, %{"operation_id" => "op-audit-rejected"})
      ]

      run_and_get_results(operations)

      records = Repo.all(from r in OperationRecord, order_by: r.id)

      assert Enum.map(records, & &1.operation_id) == [
               "op-audit-open",
               "op-audit-pay",
               "op-audit-rejected"
             ]

      assert Enum.map(records, & &1.type) == [
               "open_group",
               "record_cash_payment",
               "record_cash_payment"
             ]

      submissions = Enum.map(records, &Jason.decode!(&1.submission))

      assert hd(submissions)["rooms"] ==
               open_operation()["rooms"]

      assert Enum.at(submissions, 1)["amount_cents"] == 250
      assert Enum.at(submissions, 2)["amount_cents"] == 999_999

      assert Jason.decode!(hd(records).result)["deposit_due_cents"] == 19_500
    end

    test "records persist outside the request transaction lifetime" do
      run_and_get_results([
        open_operation(%{"operation_id" => "op-persist", "group_id" => "group-persist"})
      ])

      assert %OperationRecord{} = Repo.get_by(OperationRecord, operation_id: "op-persist")

      assert Operations.get_stored_result("op-persist")["status"] == "applied"
    end

    test "operations without a usable identifier are processed untracked" do
      results = run_and_get_results(["not-an-operation"])

      assert results == [
               %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
             ]

      results = run_and_get_results([%{"type" => "cancel_group", "occurred_on" => "2026-10-04"}])

      assert hd(results) == %{
               "operation_id" => nil,
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert Repo.all(OperationRecord) == []
    end
  end

  defp run_and_get_results(operations) do
    post_operations(operations) |> json_response(200) |> Map.fetch!("results")
  end
end
