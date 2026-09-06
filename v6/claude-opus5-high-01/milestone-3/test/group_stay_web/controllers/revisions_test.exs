defmodule GroupStayWeb.RevisionsTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  describe "revisions" do
    test "every applied operation advances the revision exactly once", %{conn: conn} do
      assert %{"revision" => 1} = submit_one(conn, open_group_op())
      assert %{"revision" => 2} = submit_one(conn, payment_op())
      assert %{"revision" => 3} = submit_one(conn, reschedule_op())
      assert %{"revision" => 4} = submit_one(conn, cancel_op())
      assert %{"revision" => 4} = read_group(conn, "group-81")
    end

    test "a reschedule that does not move the stay still advances the revision", %{conn: conn} do
      submit_one(conn, open_group_op())

      assert %{"revision" => 2, "new_arrival_on" => "2026-12-10"} =
               submit_one(conn, reschedule_op(%{new_arrival_on: "2026-12-10"}))
    end

    test "applies an operation whose expected revision matches", %{conn: conn} do
      submit_one(conn, open_group_op())

      assert %{"status" => "applied", "revision" => 2} =
               submit_one(conn, payment_op(%{expected_revision: 1}))

      assert %{"status" => "applied", "revision" => 3} =
               submit_one(conn, reschedule_op(%{expected_revision: 2}))

      assert %{"status" => "applied", "revision" => 4} =
               submit_one(conn, cancel_op(%{expected_revision: 3}))
    end

    test "rejects a stale revision and changes nothing", %{conn: conn} do
      submit_one(conn, open_group_op())
      submit_one(conn, payment_op())

      assert %{
               "operation_id" => "op-2",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             } =
               submit_one(conn, payment_op(%{operation_id: "op-2", expected_revision: 1}))

      assert %{"revision" => 2, "deposit_paid_cents" => 10_000} = read_group(conn, "group-81")
      assert %{"cash_held_cents" => 10_000} = read_ledger(conn)
    end

    test "resolves group existence before comparing revisions", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "group_not_found"} =
               submit_one(conn, payment_op(%{group_id: "group-none", expected_revision: 7}))
    end

    test "compares revisions before other domain rules", %{conn: conn} do
      submit_one(conn, open_group_op())
      submit_one(conn, cancel_op())

      assert %{"code" => "stale_revision", "actual_revision" => 2} =
               submit_one(
                 conn,
                 payment_op(%{
                   operation_id: "op-pay-stale",
                   expected_revision: 1,
                   amount_cents: 999_999
                 })
               )

      assert %{"code" => "stale_revision"} =
               submit_one(
                 conn,
                 reschedule_op(%{expected_revision: 1, new_arrival_on: "1999-01-01"})
               )

      assert %{"code" => "stale_revision"} =
               submit_one(
                 conn,
                 cancel_op(%{operation_id: "op-cancel-stale", expected_revision: 1})
               )

      assert %{"revision" => 2} = read_group(conn, "group-81")
    end

    test "sees revisions produced earlier in the same batch", %{conn: conn} do
      assert %{"results" => results} =
               submit(conn, [
                 open_group_op(),
                 payment_op(%{operation_id: "op-2", expected_revision: 1}),
                 payment_op(%{operation_id: "op-3", expected_revision: 1}),
                 payment_op(%{operation_id: "op-4", expected_revision: 2, amount_cents: 9500})
               ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2},
               %{"status" => "applied", "revision" => 3}
             ] = results
    end

    test "an unusable expected revision is not a valid operation", %{conn: conn} do
      submit_one(conn, open_group_op())

      for {expected, index} <- Enum.with_index(["1", 1.0, true]) do
        assert %{"status" => "rejected", "code" => "invalid_operation"} =
                 submit_one(
                   conn,
                   payment_op(%{operation_id: "op-pay-#{index}", expected_revision: expected})
                 ),
               "expected invalid_operation for #{inspect(expected)}"
      end
    end

    test "open_group ignores expected_revision", %{conn: conn} do
      assert %{"status" => "applied", "revision" => 1} =
               submit_one(conn, open_group_op(%{expected_revision: 7}))
    end
  end
end
