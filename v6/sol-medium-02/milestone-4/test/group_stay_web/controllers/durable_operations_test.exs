defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.{Operations, PartnerOperation, Repo}

  defp open_operation(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
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

  defp payment(operation_id, group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "replays an applied result exactly without observing or changing later state", %{
    conn: conn
  } do
    paid =
      payment("pay-once", "group-1", 5_000, %{
        "partner_context" => %{"trace" => "abc", "flags" => [1, 2]}
      })

    [_, original] = submit(conn, [open_operation("open-1", "group-1"), paid])
    assert original["revision"] == 2
    assert original["outstanding_deposit_cents"] == 14_500

    [later, replay] =
      submit(conn, [payment("pay-later", "group-1", 2_000), paid])

    assert later["revision"] == 3
    assert replay == original

    assert conn |> get("/api/v1/operations/pay-once") |> json_response(200) ==
             %{"data" => original}

    group = conn |> get("/api/v1/groups/group-1") |> json_response(200) |> Map.fetch!("data")
    assert group["cash_paid_cents"] == 7_000
    assert group["revision"] == 3

    stored = Repo.get_by!(PartnerOperation, operation_id: "pay-once")
    assert stored.operation_type == "record_cash_payment"
    assert stored.submission == paid
  end

  test "remembers a rejection even after domain state would make it valid", %{conn: conn} do
    missing_payment = payment("missing-pay", "later-group", 1_000)

    [original, opened, replay] =
      submit(conn, [
        missing_payment,
        open_operation("open-later", "later-group"),
        missing_payment
      ])

    assert original == %{
             "operation_id" => "missing-pay",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "later-group"
           }

    assert opened["status"] == "applied"
    assert replay == original

    group =
      conn |> get("/api/v1/groups/later-group") |> json_response(200) |> Map.fetch!("data")

    assert group["cash_paid_cents"] == 0
    assert group["revision"] == 1

    assert conn |> get("/api/v1/operations/missing-pay") |> json_response(200) ==
             %{"data" => original}
  end

  test "conflicting reuse preserves stale details and does not stop the batch", %{conn: conn} do
    stale = payment("stale-pay", "group-1", 500, %{"expected_revision" => 1})

    [_, _, original] =
      submit(conn, [
        open_operation("open-1", "group-1"),
        payment("first-pay", "group-1", 1_000),
        stale
      ])

    assert original["code"] == "stale_revision"
    assert original["expected_revision"] == 1
    assert original["actual_revision"] == 2

    corrected = Map.put(stale, "expected_revision", 2)

    [conflict, later] =
      submit(conn, [corrected, payment("later-pay", "group-1", 500)])

    assert conflict == %{
             "operation_id" => "stale-pay",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert later["revision"] == 3

    [replay] = submit(conn, [stale])
    assert replay == original

    assert conn |> get("/api/v1/operations/stale-pay") |> json_response(200) ==
             %{"data" => original}
  end

  test "object ordering is irrelevant while array order and values remain significant", %{
    conn: conn
  } do
    operation = open_operation("ordered-open", "ordered-group")
    [original] = submit(conn, [operation])

    reordered_objects =
      operation
      |> Enum.reverse()
      |> Map.new(fn
        {"rooms", rooms} -> {"rooms", Enum.map(rooms, &(&1 |> Enum.reverse() |> Map.new()))}
        pair -> pair
      end)

    assert submit(conn, [reordered_objects]) == [original]

    reversed_rooms = Map.update!(operation, "rooms", &Enum.reverse/1)
    [conflict] = submit(conn, [reversed_rooms])
    assert conflict["code"] == "operation_id_conflict"

    changed_value = put_in(operation, ["rooms", Access.at(0), "nightly_rate_cents"], 15_001)
    [conflict] = submit(conn, [changed_value])
    assert conflict["code"] == "operation_id_conflict"

    assert Repo.aggregate(PartnerOperation, :count) == 1
  end

  test "audit rows retain complete submissions in first-commit order", %{conn: conn} do
    rejected = %{
      "operation_id" => "bad-first",
      "type" => "unknown_type",
      "occurred_on" => "2026-10-03",
      "opaque" => %{"nested" => [true, nil, %{"answer" => 42}]}
    }

    applied = open_operation("good-second", "group-1", %{"extra" => "retained"})
    submit(conn, [rejected, applied])

    rows = Repo.all(from operation in PartnerOperation, order_by: [asc: operation.id])
    assert Enum.map(rows, & &1.operation_id) == ["bad-first", "good-second"]
    assert Enum.map(rows, & &1.operation_type) == ["unknown_type", "open_group"]
    assert Enum.map(rows, & &1.submission) == [rejected, applied]
    assert Enum.map(rows, & &1.result["status"]) == ["rejected", "applied"]
  end

  test "concurrent identical submissions have one effect and one result" do
    operation = open_operation("concurrent-open", "concurrent-group")

    results =
      1..2
      |> Task.async_stream(fn _ -> Operations.apply_batch([operation]) end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert [first, second] = results
    assert first == second
    assert Repo.aggregate(PartnerOperation, :count) == 1
    assert {:ok, group} = Operations.get_group("concurrent-group")
    assert group.revision == 1
  end

  test "an unexpected database fault rolls back the operation and aborts later work", %{
    conn: conn
  } do
    Repo.query!("""
    CREATE TRIGGER fail_operation_result
    BEFORE UPDATE OF result ON partner_operations
    WHEN NEW.operation_id = 'explode'
    BEGIN
      SELECT RAISE(ABORT, 'deliberate test fault');
    END
    """)

    on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS fail_operation_result") end)

    assert_raise Exqlite.Error, fn ->
      submit(conn, [
        open_operation("explode", "rolled-back"),
        open_operation("never-ran", "not-created")
      ])
    end

    assert {:error, :group_not_found} = Operations.get_group("rolled-back")
    assert {:error, :group_not_found} = Operations.get_group("not-created")
    assert {:error, :operation_not_found} = Operations.get_operation_result("explode")
    assert {:error, :operation_not_found} = Operations.get_operation_result("never-ran")
  end

  test "returns operation_not_found for an unknown operation", %{conn: conn} do
    assert conn |> get("/api/v1/operations/absent") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end
end
