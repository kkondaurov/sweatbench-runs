defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.PartnerOperation

  test "an applied operation replays its exact original result without consulting current state",
       %{
         conn: conn
       } do
    open = open_operation()

    assert [original] = post_batch(conn, [open])
    assert original["revision"] == 1

    post_batch(build_conn(), [payment_operation("pay-1", 1_000, 1)])

    assert post_batch(build_conn(), [open]) == [original]
    assert get_group("group-1")["revision"] == 2
  end

  test "rejected operations replay even after domain state changes", %{conn: conn} do
    payment = payment_operation("missing-payment", 1_000)

    assert [original] = post_batch(conn, [payment])
    assert original["code"] == "group_not_found"

    post_batch(build_conn(), [open_operation()])

    assert post_batch(build_conn(), [payment]) == [original]
    assert get_group("group-1")["revision"] == 1
  end

  test "reusing an operation id with a different payload conflicts and preserves the record", %{
    conn: conn
  } do
    original = open_operation()
    [original_result] = post_batch(conn, [original])

    conflict = put_in(original, ["rooms", Access.at(0), "nightly_rate_cents"], 20_000)

    assert post_batch(build_conn(), [conflict]) == [
             %{
               "operation_id" => "open-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
           ]

    assert get_group("group-1")["lodging_total_cents"] == 45_000

    assert json_response(get(build_conn(), "/api/v1/operations/open-1"), 200) == %{
             "data" => original_result
           }

    assert Repo.aggregate(PartnerOperation, :count) == 1
  end

  test "stale details are replayed verbatim and a corrected revision conflicts", %{conn: conn} do
    post_batch(conn, [open_operation(), payment_operation("pay", 1_000, 1)])
    stale = payment_operation("stale", 500, 1)

    assert [original] = post_batch(build_conn(), [stale])

    assert original == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-1",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    post_batch(build_conn(), [payment_operation("later", 500, 2)])
    assert post_batch(build_conn(), [stale]) == [original]

    assert [conflict] =
             post_batch(build_conn(), [payment_operation("stale", 500, 3)])

    assert conflict["code"] == "operation_id_conflict"
  end

  test "durable records retain submissions, types, and first-commit order", %{conn: conn} do
    first =
      open_operation()
      |> Map.put("gateway_metadata", %{
        "flags" => ["priority", %{"reviewed" => false}],
        "attempt" => 1
      })

    second = %{
      "operation_id" => "unknown-1",
      "type" => "future_operation",
      "occurred_on" => "2026-10-04",
      "content" => %{"nested" => [3, 2, 1]}
    }

    post_batch(conn, [first, second])
    post_batch(build_conn(), [first])

    records = Repo.all(from(operation in PartnerOperation, order_by: operation.id))

    assert Enum.map(records, & &1.operation_id) == ["open-1", "unknown-1"]
    assert Enum.map(records, & &1.operation_type) == ["open_group", "future_operation"]
    assert Enum.map(records, & &1.submission) == [first, second]
    assert List.last(records).result["code"] == "invalid_operation"
  end

  test "concurrent identical retries have at-most-once effects", %{conn: conn} do
    post_batch(conn, [open_operation()])
    payment = payment_operation("same-payment", 1_000, 1)

    results =
      1..2
      |> Task.async_stream(
        fn _ -> GroupStay.Reservations.apply_batch([payment]) |> hd() end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.uniq(results) |> length() == 1
    assert hd(results).revision == 2
    assert get_group("group-1")["cash_paid_cents"] == 1_000
    assert Repo.aggregate(PartnerOperation, :count) == 2
  end

  test "concurrent different payloads sharing an id apply exactly one payload", %{conn: conn} do
    post_batch(conn, [open_operation()])

    payments = [
      payment_operation("racing-payment", 1_000, 1),
      payment_operation("racing-payment", 2_000, 1)
    ]

    results =
      payments
      |> Task.async_stream(
        fn payment -> GroupStay.Reservations.apply_batch([payment]) |> hd() end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.sort(Enum.map(results, & &1.status)) == ["applied", "rejected"]
    assert Enum.find(results, &(&1.status == "rejected")).code == "operation_id_conflict"

    applied_amount = Enum.find(results, &(&1.status == "applied")).amount_cents
    assert applied_amount in [1_000, 2_000]
    assert get_group("group-1")["cash_paid_cents"] == applied_amount
    assert Repo.aggregate(PartnerOperation, :count) == 2
  end

  test "JSON object key order does not affect payload equivalence", %{conn: conn} do
    first =
      ~s({"operations":[{"operation_id":"ordered","type":"future","content":{"a":1,"b":2}}]})

    reordered =
      ~s({"operations":[{"content":{"b":2,"a":1},"type":"future","operation_id":"ordered"}]})

    original = post_json(conn, first)
    assert post_json(build_conn(), reordered) == original
    assert Repo.aggregate(PartnerOperation, :count) == 1
  end

  test "operation result reads return remembered rejections and the documented missing error", %{
    conn: conn
  } do
    [result] = post_batch(conn, [%{"operation_id" => "bad", "type" => "unknown"}])

    assert json_response(get(build_conn(), "/api/v1/operations/bad"), 200) == %{
             "data" => result
           }

    assert json_response(get(build_conn(), "/api/v1/operations/not-there"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  defp open_operation do
    %{
      "operation_id" => "open-1",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-1",
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
    }
  end

  defp payment_operation(operation_id, amount, expected_revision \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => amount
    }
    |> maybe_put("expected_revision", expected_revision)
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_group(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
