defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  @moduletag :capture_log

  defp run_batch(conn, operations) do
    conn |> submit_batch(operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp group_json(conn, group_id) do
    %{"data" => group} = conn |> get_group(group_id) |> json_response(200)
    group
  end

  defp payment(operation_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  describe "the durable record as an audit trail" do
    test "retains type, complete submission, and commit order for every remembered operation",
         %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        payment("op-pay", "group-81", 1000),
        %{"operation_id" => "op-bad", "type" => "teleport_group"}
      ])

      records =
        GroupStay.Repo.all(GroupStay.Groups.OperationRecord)

      assert Enum.map(records, &{&1.operation_id, &1.type}) == [
               {"op-open", "open_group"},
               {"op-pay", "record_cash_payment"},
               {"op-bad", "teleport_group"}
             ]

      # The retained submission is the complete submitted content; object key
      # order is normalized away.
      assert hd(records).submission["rooms"] ==
               Enum.map(open_operation()["rooms"], fn room ->
                 Map.new(room, fn {k, v} -> {k, v} end)
               end)
    end
  end

  defp fetch_operation(conn, operation_id) do
    Phoenix.ConnTest.dispatch(
      conn,
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/operations/" <> operation_id,
      nil
    )
  end

  describe "retrying an operation identifier with an equivalent payload" do
    test "returns the exact original result and leaves domain state untouched", %{conn: conn} do
      first = run_batch(conn, [open_operation()])

      # The same submission with every JSON object's keys in a different order.
      reordered = %{
        "rooms" => [
          %{"nightly_rate_cents" => 15_000, "room_id" => "room-a"},
          %{"nightly_rate_cents" => 17_500, "room_id" => "room-b"}
        ],
        "rate_plan" => "flexible",
        "departure_on" => "2026-12-13",
        "arrival_on" => "2026-12-10",
        "property_id" => "ams-canal",
        "guest_id" => "guest-22",
        "group_id" => "group-81",
        "occurred_on" => "2026-10-03",
        "type" => "open_group",
        "operation_id" => "op-open"
      }

      assert run_batch(conn, [reordered]) == first

      # The retry neither read nor changed current domain state.
      assert group_json(conn, "group-81")["revision"] == 1
      ledger = conn |> get_ledger() |> json_response(200)
      assert ledger["data"]["cash_held_cents"] == 0
    end

    test "a stale rejection is replayed verbatim even after later operations would make it valid",
         %{conn: conn} do
      run_batch(conn, [open_operation()])

      stale = payment("op-stale-pay", "group-81", 5000, %{"expected_revision" => 7})

      assert [%{"status" => "rejected", "code" => "stale_revision"} = rejection] =
               run_batch(conn, [stale])

      assert rejection["actual_revision"] == 1
      assert rejection["expected_revision"] == 7

      # Advance the group so a fresh attempt with expected_revision 7 would pass.
      run_batch(conn, [payment("op-first-pay", "group-81", 1000)])
      assert group_json(conn, "group-81")["revision"] == 2

      assert run_batch(conn, [stale]) == [rejection]

      # The replayed rejection changed nothing.
      group = group_json(conn, "group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 1000

      # Retrying under the same identifier with a corrected expected_revision is a
      # different payload.
      corrected = Map.put(stale, "expected_revision", 2)
      assert [%{"code" => "operation_id_conflict"}] = run_batch(conn, [corrected])
    end

    test "an invalid_operation rejection is remembered like any other result", %{conn: conn} do
      invalid = %{"operation_id" => "op-invalid", "type" => "teleport_group"}

      assert [%{"status" => "rejected", "code" => "invalid_operation"} = rejection] =
               run_batch(conn, [invalid])

      assert run_batch(conn, [invalid]) == [rejection]
    end
  end

  describe "reusing an operation identifier with a different payload" do
    test "is rejected without replacing the original record", %{conn: conn} do
      assert [%{"status" => "applied"} = original] = run_batch(conn, [open_operation()])

      conflicting = open_operation(arrival_on: "2026-12-11")

      assert run_batch(conn, [conflicting]) == [
               %{
                 "operation_id" => "op-open",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]

      # The original record survives: an equivalent retry still replays it.
      assert run_batch(conn, [open_operation()]) == [original]

      assert conn |> fetch_operation("op-open") |> json_response(200) == %{"data" => original}

      # Array order is significant, so swapping rooms is also a different payload.
      swapped_rooms = Map.update!(open_operation(), "rooms", &Enum.reverse/1)

      assert [%{"code" => "operation_id_conflict"}] = run_batch(conn, [swapped_rooms])
    end
  end

  describe "batch continuation around handled rejections" do
    test "a remembered rejection does not stop later operations", %{conn: conn} do
      results =
        run_batch(conn, [
          open_operation(),
          payment("op-too-much", "group-81", 999_999),
          payment("op-after", "group-81", 5000)
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
               %{"status" => "applied"}
             ] = results

      # The rejected middle operation is durably remembered too.
      assert run_batch(conn, [
               payment("op-too-much", "group-81", 999_999),
               payment("op-after", "group-81", 5000)
             ]) == Enum.drop(results, 1)
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result for applied and rejected operations", %{conn: conn} do
      [applied, rejected] =
        run_batch(conn, [
          open_operation(),
          payment("op-rejected", "ghost-group", 1000)
        ])

      assert conn |> fetch_operation("op-open") |> json_response(200) == %{"data" => applied}
      assert conn |> fetch_operation("op-rejected") |> json_response(200) == %{"data" => rejected}
    end

    test "returns operation_not_found for unknown identifiers", %{conn: conn} do
      conn = fetch_operation(conn, "never-seen")

      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end
  end

  describe "unexpected server faults" do
    test "abort the request and are not remembered as idempotent results", %{conn: conn} do
      # A nightly rate whose lodging total overflows SQLite's 64-bit integers makes
      # the domain insert fail after parsing succeeded.
      broken =
        put_in(
          open_operation(operation_id: "op-fault"),
          [
            "rooms",
            Access.at(0),
            "nightly_rate_cents"
          ],
          9_300_000_000_000_000_000
        )

      raised? =
        try do
          _conn = submit_batch(conn, [broken])
          false
        rescue
          _ -> true
        end

      assert raised?, "expected the request to abort"

      # Nothing about the failed attempt was remembered: no group was created and
      # the identifier still accepts a new, valid operation.
      conn = get_group(build_conn(), "group-81")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}

      assert [%{"status" => "applied"}] =
               run_batch(build_conn(), [
                 open_operation(operation_id: "op-fault")
               ])
    end
  end
end
