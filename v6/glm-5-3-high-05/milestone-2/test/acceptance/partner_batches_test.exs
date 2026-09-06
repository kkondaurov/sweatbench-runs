defmodule GroupStayWeb.Acceptance.PartnerBatchesTest do
  use GroupStayWeb.ConnCase, async: true

  describe "submitting a batch" do
    test "applies operations in order and returns one result per operation" do
      conn =
        post_batch(build_conn(), [
          open_group_operation(%{"operation_id" => "op-1"}),
          record_cash_operation(%{"operation_id" => "op-2", "amount_cents" => 5000}),
          reschedule_operation(%{"operation_id" => "op-3", "new_arrival_on" => "2026-12-20"}),
          cancel_operation(%{"operation_id" => "op-4", "occurred_on" => "2026-11-26"})
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-1",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-2",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 5000,
                   "outstanding_deposit_cents" => 14500,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-3",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-23",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2026-12-06",
                   "revision" => 3
                 },
                 %{
                   "operation_id" => "op-4",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 5000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)
    end

    test "an operation observes changes made by an earlier operation in the batch" do
      conn =
        post_batch(build_conn(), [
          open_group_operation(%{"group_id" => "group-early"}),
          record_cash_operation(%{"group_id" => "group-early", "amount_cents" => 19500})
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied", "outstanding_deposit_cents" => 0}
               ]
             } = json_response(conn, 200)
    end

    test "a rejected operation does not undo earlier operations and does not stop later ones" do
      conn =
        post_batch(build_conn(), [
          open_group_operation(%{"group_id" => "group-keep"}),
          record_cash_operation(%{"group_id" => "group-missing"}),
          cancel_operation(%{"group_id" => "group-keep", "occurred_on" => "2026-11-26"})
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "group_id" => "group-keep"},
                 %{"status" => "rejected", "code" => "group_not_found"},
                 %{"status" => "applied", "group_id" => "group-keep"}
               ]
             } = json_response(conn, 200)
    end

    test "an empty operations array returns an empty results array" do
      conn = post_batch(build_conn(), [])
      assert %{"results" => []} = json_response(conn, 200)
    end

    test "a body without an operations array is an invalid batch" do
      conn = post(build_conn(), "/api/v1/partner-batches", %{"something" => "else"})
      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)

      conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => "nope"})
      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)

      conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => %{}})
      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "operations that are not objects are rejected with invalid_operation" do
      conn = post_batch(build_conn(), ["pay everything", 42, nil])

      assert %{
               "results" => [
                 %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"},
                 %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"},
                 %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
               ]
             } = json_response(conn, 200)
    end
  end

  describe "invalid operations" do
    test "an unknown operation type is rejected" do
      result =
        apply_one!(
          build_conn(),
          open_group_operation(%{"type" => "rename_group", "group_id" => "g"})
        )

      assert %{"status" => "rejected", "code" => "invalid_operation"} = result
      assert group_status("g") == :missing
    end

    test "a missing operation type is rejected" do
      result = apply_one!(build_conn(), Map.delete(open_group_operation(), "type"))
      assert %{"status" => "rejected", "code" => "invalid_operation"} = result
    end

    test "a missing operation_id is rejected" do
      result = apply_one!(build_conn(), Map.delete(open_group_operation(), "operation_id"))
      assert %{"status" => "rejected", "code" => "invalid_operation"} = result
    end

    test "a missing occurred_on is rejected" do
      result = apply_one!(build_conn(), Map.delete(open_group_operation(), "occurred_on"))
      assert %{"status" => "rejected", "code" => "invalid_operation"} = result
    end

    test "an unusable occurred_on is rejected" do
      result = apply_one!(build_conn(), open_group_operation(%{"occurred_on" => "not-a-date"}))
      assert %{"status" => "rejected", "code" => "invalid_operation"} = result
    end

    test "a missing group_id is rejected" do
      result = apply_one!(build_conn(), Map.delete(open_group_operation(), "group_id"))
      assert %{"status" => "rejected", "code" => "invalid_operation"} = result
    end

    test "a rejected operation leaves the database exactly as it was" do
      open_group!(build_conn(), %{"group_id" => "group-intact"})
      before = group_data("group-intact")

      result =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"group_id" => "group-intact", "amount_cents" => 0})
        )

      assert %{"status" => "rejected", "code" => "invalid_amount"} = result
      assert group_data("group-intact") == before
    end
  end

  defp group_status(group_id) do
    case get_group(build_conn(), group_id) do
      %{status: 404} -> :missing
      %{status: 200} -> :present
    end
  end

  defp group_data(group_id) do
    assert %{status: 200} = conn = get_group(build_conn(), group_id)
    json_response(conn, 200)["data"]
  end
end
