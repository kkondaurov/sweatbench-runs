defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query
  import GroupStay.OperationFixtures

  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Credit.{Allocation, Lot}
  alias GroupStay.Operations.Operation
  alias GroupStay.Reservations.Group

  test "retries return original results and revisions across batches and later changes", %{
    conn: conn
  } do
    opening = open_group()
    payment = operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
    move = operation("reschedule_group", %{"new_arrival_on" => "2027-03-01"})
    cancel = operation("cancel_group", %{"refund_method" => "hotel_credit"})
    submissions = [opening, payment, move, cancel]

    originals = batch(conn, submissions)
    assert Enum.map(originals, & &1["revision"]) == [1, 2, 3, 4]
    before = snapshot()

    assert batch(conn, submissions ++ submissions) == originals ++ originals
    assert snapshot() == before

    for result <- originals do
      assert conn
             |> recycle()
             |> get("/api/v1/operations/#{result["operation_id"]}")
             |> json_response(200) ==
               %{"data" => result}
    end

    assert Repo.one!(Lot).remaining_cents == 110
  end

  test "duplicate credit application and restoration have at-most-once effects", %{conn: conn} do
    batch(conn, [
      open_group(%{"group_id" => "source"}),
      operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 100}),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open_group()
    ])

    credit = operation("apply_hotel_credit", %{"amount_cents" => 60, "expected_revision" => 1})
    assert [first, first] = batch(conn, [credit, credit])
    assert first["revision"] == 2
    assert Repo.one!(Allocation).amount_cents == 60
    assert Repo.one!(Lot).remaining_cents == 50

    cancel = operation("cancel_group")
    assert [settlement, settlement] = batch(conn, [cancel, cancel])
    assert settlement["revision"] == 3
    assert Repo.one!(Lot).remaining_cents == 110
    assert Repo.aggregate(Allocation, :count) == 0
    assert batch(conn, [credit]) == [first]
    assert Repo.one!(Lot).remaining_cents == 110
  end

  test "rejections survive changes that would make them valid and conflicts preserve the original",
       %{conn: conn} do
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    [missing] = batch(conn, [payment])
    assert missing["code"] == "group_not_found"
    batch(conn, [open_group()])
    assert batch(conn, [payment]) == [missing]

    stale = operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 2})
    [rejected] = batch(conn, [stale])
    assert rejected["actual_revision"] == 1
    batch(conn, [operation("record_cash_payment", %{"amount_cents" => 1})])
    before = snapshot()
    assert batch(conn, [stale]) == [rejected]

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(stale, "expected_revision", 3)])

    assert Operations.get_result(stale["operation_id"]) == rejected
    assert Operations.get_result(payment["operation_id"]) == missing
    assert snapshot() == before
  end

  test "JSON object order is irrelevant, including nested objects in arrays", %{conn: conn} do
    payload = open_group(%{"operation_id" => "ordered", "extra" => [%{"a" => 1, "b" => nil}]})
    [original] = batch(conn, [payload])

    # Build JSON with every object's key order reversed, without going through a map encoder.
    json = "{\"operations\":[" <> reverse_object_json(payload) <> "]}"

    assert conn
           |> recycle()
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", json)
           |> json_response(200) == %{"results" => [original]}

    assert Repo.one!(Operation).payload === payload
    assert Repo.aggregate(Operation, :count) == 1
  end

  test "all submitted fields, array order and value types participate in conflicts", %{conn: conn} do
    payload = open_group(%{"extra" => %{"number" => 1, "nullable" => nil}})
    [original] = batch(conn, [payload])
    before = snapshot()

    variants = [
      Map.update!(payload, "rooms", &Enum.reverse/1),
      Map.put(payload, "extra", %{"number" => 1.0, "nullable" => nil}),
      Map.put(payload, "extra", %{"number" => "1", "nullable" => nil}),
      Map.put(payload, "extra", %{"number" => 1}),
      Map.put(payload, "expected_revision", nil),
      Map.put(payload, "type", "cancel_group"),
      Map.put(payload, "group_id", "different")
    ]

    assert Enum.all?(batch(conn, variants), &(&1["code"] == "operation_id_conflict"))
    assert snapshot() == before
    assert batch(conn, [payload]) == [original]
  end

  test "audit retains complete rejected submissions and first commit order", %{conn: conn} do
    unknown = %{
      "operation_id" => " z-Ä ",
      "type" => "future",
      "extra" => [true, nil, %{"x" => 2}]
    }

    malformed = %{"operation_id" => "a", "type" => ["bad"], "anything" => %{"nested" => "value"}}
    opening = open_group(%{"operation_id" => "middle"})
    submissions = [unknown, malformed, opening]
    results = batch(conn, submissions ++ [unknown, Map.put(opening, "guest_id", "other")])
    assert Enum.map(results, & &1["status"]) == ~w(rejected rejected applied rejected rejected)

    records = Repo.all(from operation in Operation, order_by: operation.id)
    assert Enum.map(records, & &1.payload) === submissions
    assert Enum.map(records, & &1.type) == ["future", nil, "open_group"]
    assert Enum.map(records, & &1.result) == Enum.take(results, 3)
    assert Operations.get_result(" z-Ä ") == hd(results)

    assert conn |> recycle() |> get("/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  test "submissions without usable identifiers are rejected without reserving a namespace", %{
    conn: conn
  } do
    invalid = [
      nil,
      [],
      3,
      %{},
      open_group(%{"operation_id" => nil}),
      open_group(%{"operation_id" => ""}),
      open_group(%{"operation_id" => 12})
    ]

    assert Enum.all?(batch(conn, invalid), &(&1["code"] == "invalid_operation"))
    assert Repo.aggregate(Operation, :count) == 0
    assert Repo.aggregate(Group, :count) == 0
  end

  test "a handled rejection rolls back domain writes but commits its audit record" do
    payload = operation("cancel_group")

    result =
      Operations.execute(payload, fn ->
        Repo.insert!(%Lot{
          guest_id: "guest",
          source_operation_id: "temporary",
          remaining_cents: 10,
          expires_on: ~D[2027-01-01]
        })

        {:error, "invalid_operation"}
      end)

    assert result.code == "invalid_operation"
    assert Repo.aggregate(Lot, :count) == 0
    assert Repo.one!(Operation).result["code"] == "invalid_operation"
    assert Operations.execute(payload, fn -> flunk("retry consulted domain state") end) == result
  end

  @tag capture_log: true
  test "an unexpected operation exception sends HTTP 500 and is not remembered", %{conn: conn} do
    opening = open_group()
    batch(conn, [opening])
    payment = operation("record_cash_payment", %{"amount_cents" => 100})

    Repo.query!("""
    CREATE TRIGGER fail_payment BEFORE UPDATE ON groups
    BEGIN SELECT RAISE(ABORT, 'injected payment failure'); END
    """)

    assert_error_sent 500, fn -> batch(conn, [payment]) end
    assert Operations.get_result(payment["operation_id"]) == nil
    assert Reservations.get_group("group-81").revision == 1

    Repo.query!("DROP TRIGGER fail_payment")
    assert [%{"revision" => 2, "amount_cents" => 100}] = batch(conn, [payment])
  end

  defp batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp snapshot do
    {Repo.all(Group), Repo.all(Lot), Repo.all(Allocation), Repo.all(Operation),
     Reservations.ledger()}
  end

  defp reverse_object_json(value) when is_map(value) do
    fields =
      value
      |> Enum.sort(:desc)
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> reverse_object_json(value)
      end)

    "{" <> fields <> "}"
  end

  defp reverse_object_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &reverse_object_json/1) <> "]"

  defp reverse_object_json(value), do: Jason.encode!(value)
end
