defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: true

  @moduletag :capture_log

  describe "POST /api/v1/partner-batches with open_group" do
    test "applies the documented example and returns the applied result" do
      conn = post_operations([open_operation()])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }
    end

    test "records the operation date as the booked_on date and keeps room order" do
      post_operations([
        open_operation(%{
          "group_id" => "group-rooms",
          "rooms" => [
            %{"room_id" => "room-z", "nightly_rate_cents" => 10_000},
            %{"room_id" => "room-a", "nightly_rate_cents" => 12_000}
          ]
        })
      ])

      assert %{
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-z", "nightly_rate_cents" => 10_000},
                 %{"room_id" => "room-a", "nightly_rate_cents" => 12_000}
               ],
               "lodging_total_cents" => 66_000
             } = fetch_group("group-rooms")
    end

    test "advance_purchase rooms deposit their full lodging amount" do
      conn =
        post_operations([
          open_operation(%{
            "group_id" => "group-ap",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 9_999}]
          })
        ])

      assert hd(json_response(conn, 200)["results"]) == %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-ap",
               "deposit_due_cents" => 9_999,
               "revision" => 1
             }
    end

    test "rounds each flexible room deposit separately to the nearest cent" do
      conn =
        post_operations([
          open_operation(%{
            "operation_id" => "op-round",
            "group_id" => "group-round",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rate_plan" => "flexible",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 1_111},
              %{"room_id" => "room-b", "nightly_rate_cents" => 1_113}
            ]
          })
        ])

      # 1111 * 20% = 222.2 -> 222; 1113 * 20% = 222.6 -> 223.
      assert hd(json_response(conn, 200)["results"])["deposit_due_cents"] == 445
    end

    test "rejects a duplicate group identifier without creating anything" do
      open_default_group("group-dup")

      results = run_and_get_results([open_operation(%{"group_id" => "group-dup"})])

      assert %{"status" => "rejected", "code" => "group_already_exists"} = hd(results)
      assert revision_of("group-dup") == 1
    end

    test "rejects stays without at least one night as invalid_stay" do
      for {arrival, departure} <- [{"2026-12-10", "2026-12-10"}, {"2026-12-13", "2026-12-10"}] do
        results =
          run_and_get_results([open_operation(%{arrival_on: arrival, departure_on: departure})])

        assert %{"status" => "rejected", "code" => "invalid_stay"} = hd(results)
      end

      refute group_exists?("group-81")
    end

    test "rejects unusable dates as invalid_stay" do
      results = run_and_get_results([open_operation(%{"arrival_on" => "not-a-date"})])

      assert %{"status" => "rejected", "code" => "invalid_stay"} = hd(results)
    end

    test "rejects bad rooms as invalid_rooms" do
      cases = [
        empty_rooms: open_operation(%{"rooms" => []}),
        duplicate_ids:
          open_operation(%{
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 100},
              %{"room_id" => "room-a", "nightly_rate_cents" => 100}
            ]
          }),
        zero_rate:
          open_operation(%{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 0}]}),
        negative_rate:
          open_operation(%{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -5}]}),
        non_integer_rate:
          open_operation(%{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15.5}]}),
        missing_room_id: open_operation(%{"rooms" => [%{"nightly_rate_cents" => 150}]}),
        not_a_list: open_operation(%{"rooms" => %{"room_id" => "room-a"}}),
        malformed_entry: open_operation(%{"rooms" => ["room-a"]})
      ]

      for {_case, operation} <- cases do
        results = run_and_get_results([operation])

        assert hd(results)["code"] == "invalid_rooms"
      end

      refute group_exists?("group-81")
    end

    test "rejects unknown rate plans as invalid_rate_plan" do
      results = run_and_get_results([open_operation(%{"rate_plan" => "super_saver"})])

      assert %{"status" => "rejected", "code" => "invalid_rate_plan"} = hd(results)
    end

    test "rejects operations missing data needed to apply them as invalid_operation" do
      base = open_operation()

      cases = [
        Map.delete(base, "operation_id"),
        Map.delete(base, "occurred_on"),
        Map.delete(base, "group_id"),
        Map.delete(base, "guest_id"),
        Map.delete(base, "property_id"),
        Map.delete(base, "arrival_on"),
        Map.delete(base, "departure_on"),
        Map.delete(base, "rate_plan"),
        Map.delete(base, "rooms")
      ]

      for operation <- cases do
        results = run_and_get_results([operation])

        assert hd(results) == %{
                 "operation_id" => Map.get(operation, "operation_id"),
                 "status" => "rejected",
                 "code" => "invalid_operation"
               }
      end

      refute group_exists?("group-81")
    end
  end

  describe "POST /api/v1/partner-batches batch handling" do
    test "a body without an operations array is an invalid batch" do
      for body <- [
            Jason.encode!(%{}),
            Jason.encode!(%{"operations" => %{"type" => "open_group"}}),
            Jason.encode!(%{"operations" => "nope"})
          ] do
        conn = post_raw_body(body)

        assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
      end
    end

    test "an empty operations array succeeds with no results" do
      conn = post_operations([])

      assert json_response(conn, 200) == %{"results" => []}
    end

    test "later operations observe changes from earlier operations in the same batch" do
      results =
        run_and_get_results([
          open_operation(),
          pay_operation("group-81", 19_500)
        ])

      assert [%{"status" => "applied", "revision" => 1}, second] = results

      assert second == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 19_500,
               "outstanding_deposit_cents" => 0,
               "revision" => 2
             }

      assert fetch_group("group-81")["outstanding_deposit_cents"] == 0
    end

    test "rejections neither undo earlier operations nor stop later ones" do
      results =
        run_and_get_results([
          open_operation(%{"operation_id" => "op-1"}),
          open_operation(%{"operation_id" => "op-2", "group_id" => "group-81"}),
          pay_operation("group-81", 19_500, %{"operation_id" => "op-3"}),
          pay_operation("missing-group", 100, %{"operation_id" => "op-4"})
        ])

      codes = Enum.map(results, & &1["status"])

      assert codes == ["applied", "rejected", "applied", "rejected"]
      assert fetch_group("group-81")["deposit_paid_cents"] == 19_500
    end

    test "unknown operation types are rejected with invalid_operation" do
      results =
        run_and_get_results([
          %{"operation_id" => "op-x", "type" => "teleport_group", "group_id" => "group-81"}
        ])

      assert results == [
               %{"operation_id" => "op-x", "status" => "rejected", "code" => "invalid_operation"}
             ]
    end

    test "entries that are not objects are rejected with invalid_operation" do
      results = run_and_get_results(["not-an-operation"])

      assert results == [
               %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
             ]
    end
  end

  defp run_and_get_results(operations) do
    post_operations(operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp group_exists?(group_id) do
    conn = build_conn() |> get("/api/v1/groups/#{URI.encode_www_form(group_id)}")

    conn.status == 200
  end

  defp revision_of(group_id), do: fetch_group(group_id)["revision"]
end
