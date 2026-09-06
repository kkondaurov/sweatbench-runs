defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query
  import GroupStay.ReservationFixtures
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.PartnerOperations.Operation
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group}

  test "retries every operation type verbatim in a batch and after later domain changes", %{
    conn: conn
  } do
    operations = [
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 105, "expected_revision" => 1}),
      operation("reschedule_group", %{
        "new_arrival_on" => "2027-04-01",
        "expected_revision" => 2
      }),
      operation("cancel_group", %{"refund_method" => "hotel_credit", "expected_revision" => 3}),
      open_operation(%{"group_id" => "target"}),
      operation("record_cash_payment", %{
        "group_id" => "target",
        "amount_cents" => 50,
        "expected_revision" => 1
      }),
      operation("apply_hotel_credit", %{
        "group_id" => "target",
        "amount_cents" => 100,
        "expected_revision" => 2
      }),
      operation("cancel_group", %{"group_id" => "target", "expected_revision" => 3})
    ]

    results = batch(conn, Enum.flat_map(operations, &[&1, &1]))
    originals = Enum.take_every(results, 2)
    assert originals == results |> Enum.drop(1) |> Enum.take_every(2)
    assert Enum.all?(originals, &(&1["status"] == "applied"))
    assert Enum.map(originals, & &1["revision"]) == [1, 2, 3, 4, 1, 2, 3, 4]
    assert Enum.at(originals, 2)["refundable_until"] == "2027-03-18"
    assert Enum.at(originals, 3)["credit_issued_cents"] == 116
    assert List.last(originals)["refunded_cents"] == 50

    before = snapshot()
    assert batch(conn, operations) == originals
    assert snapshot() == before
    assert Reservations.get_group("group-81").revision == 4
    assert Reservations.get_group("target").revision == 4
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 116
    assert Reservations.ledger(~D[2026-10-04]).cash_refunded_cents == 50
    assert Repo.aggregate(Operation, :count) == length(operations)

    for {operation, result} <- Enum.zip(operations, originals) do
      assert lookup(conn, operation["operation_id"]) == result
    end
  end

  test "remembers rejections even when subsequent operations would make them valid", %{conn: conn} do
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    credit = operation("apply_hotel_credit", %{"amount_cents" => 110})

    [missing, _, still_missing, insufficient | _] =
      batch(conn, [
        payment,
        open_operation(),
        payment,
        credit,
        open_operation(%{"group_id" => "source"}),
        operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 100}),
        operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"})
      ])

    assert missing["code"] == "group_not_found"
    assert still_missing == missing
    assert insufficient["code"] == "insufficient_credit"
    before = snapshot()
    assert batch(conn, [payment, credit]) == [missing, insufficient]
    assert lookup(conn, payment["operation_id"]) == missing
    assert lookup(conn, credit["operation_id"]) == insufficient
    assert snapshot() == before

    assert [%{"status" => "applied"}, %{"status" => "applied"}] =
             batch(conn, [
               Map.put(payment, "operation_id", "fresh-payment"),
               Map.put(credit, "operation_id", "fresh-credit")
             ])
  end

  test "stale details remain exact and correcting the revision conflicts before domain validation",
       %{
         conn: conn
       } do
    stale = operation("record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 0})
    [_, original, _] = batch(conn, [open_operation(), stale, operation("cancel_group")])

    assert original == %{
             "operation_id" => stale["operation_id"],
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    before = snapshot()
    assert batch(conn, [stale]) == [original]

    for changed <- [
          Map.put(stale, "expected_revision", 2),
          Map.delete(stale, "expected_revision"),
          Map.put(stale, "group_id", "missing"),
          Map.put(stale, "type", "unknown")
        ] do
      assert_conflict(conn, changed)
    end

    assert lookup(conn, stale["operation_id"]) == original
    assert snapshot() == before
  end

  test "JSON object order is irrelevant at every depth and the complete submission is retained",
       %{
         conn: conn
       } do
    submitted =
      open_operation(%{
        "operation_id" => " Op-Å-001 ",
        "metadata" => %{
          "unknown" => [nil, true, false, 1.5, 9_007_199_254_740_993, %{"b" => 2, "a" => 1}],
          "empty" => %{}
        }
      })

    forward = encode_ordered(submitted, :asc)
    reversed = encode_ordered(submitted, :desc)
    refute forward == reversed
    [result] = raw_batch(conn, "{\"operations\":[#{forward}]}")
    assert raw_batch(conn, "{\"operations\":[#{reversed}]}") == [result]
    assert lookup(conn, submitted["operation_id"]) == result

    assert [%Operation{payload: payload, type: "open_group", result: stored}] =
             Repo.all(Operation)

    assert payload === submitted
    assert stored == result
  end

  test "array order, omitted fields, JSON types, and ignored values distinguish submissions", %{
    conn: conn
  } do
    submitted = open_operation(%{"extra" => [1, 2], "flag" => nil})
    [original] = batch(conn, [submitted])
    before = snapshot()

    for changed <- [
          Map.put(submitted, "rooms", Enum.reverse(submitted["rooms"])),
          Map.put(submitted, "extra", [2, 1]),
          Map.put(submitted, "extra", [1.0, 2]),
          Map.put(submitted, "extra", ["1", 2]),
          Map.put(submitted, "extra", [true, 2]),
          Map.put(submitted, "extra", [1, 2, 3]),
          Map.delete(submitted, "flag"),
          Map.put(submitted, "flag", false),
          Map.put(submitted, "new_field", nil)
        ] do
      assert_conflict(conn, changed)
    end

    assert batch(conn, [submitted]) == [original]
    assert snapshot() == before
  end

  test "invalid operations with usable IDs retain all submitted data and their original rejection",
       %{conn: conn} do
    submissions = [
      %{"operation_id" => "missing-type", "extra" => [1, %{"deep" => true}]},
      %{"operation_id" => "bad-type", "type" => %{"arbitrary" => [nil, 5]}},
      %{"operation_id" => "unknown-type", "type" => "future_operation", "group_id" => "missing"},
      %{"operation_id" => "missing-fields", "type" => "open_group"}
    ]

    results = batch(conn, submissions)
    assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    assert batch(conn, submissions) == results
    assert Repo.all(Group) == []

    records = Repo.all(from record in Operation, order_by: record.id)
    assert Enum.map(records, & &1.payload) === submissions
    assert Enum.map(records, & &1.result) == results
    assert Enum.map(records, & &1.type) == [nil, nil, "future_operation", "open_group"]

    for {submission, result} <- Enum.zip(submissions, results) do
      assert lookup(conn, submission["operation_id"]) == result
      assert_conflict(conn, open_operation(%{"operation_id" => submission["operation_id"]}))
    end
  end

  test "unusable operation identifiers remain invalid without reserving a namespace", %{
    conn: conn
  } do
    malformed = [nil, [], "operation", 123, true, %{}]

    invalid_ids =
      for id <- [nil, "", 123, true, [], %{}], do: open_operation(%{"operation_id" => id})

    results = batch(conn, malformed ++ invalid_ids ++ [open_operation()])
    assert Enum.all?(Enum.drop(results, -1), &(&1["code"] == "invalid_operation"))
    assert List.last(results)["status"] == "applied"
    assert Repo.aggregate(Operation, :count) == 1

    assert conn |> get("/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  test "first commit order includes rejections and excludes retries and conflicts", %{conn: conn} do
    rejected =
      operation("record_cash_payment", %{"operation_id" => "z-first", "amount_cents" => 10})

    opening = open_operation(%{"operation_id" => "m-second"})

    payment =
      operation("record_cash_payment", %{"operation_id" => "a-third", "amount_cents" => 10})

    results =
      batch(conn, [
        rejected,
        opening,
        rejected,
        Map.put(opening, "guest_id", "conflict"),
        payment,
        opening
      ])

    assert Enum.map(results, & &1["status"]) ==
             ~w(rejected applied rejected rejected applied applied)

    records = Repo.all(from record in Operation, order_by: record.id)
    assert Enum.map(records, & &1.operation_id) == ~w(z-first m-second a-third)
    assert Enum.map(records, & &1.payload) == [rejected, opening, payment]
    assert Enum.map(records, & &1.result) == Enum.map([0, 1, 4], &Enum.at(results, &1))
  end

  defp batch(conn, operations), do: raw_batch(conn, Jason.encode!(%{operations: operations}))

  defp raw_batch(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp lookup(conn, id) do
    conn
    |> get("/api/v1/operations/#{URI.encode(id, &URI.char_unreserved?/1)}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp assert_conflict(conn, operation) do
    assert batch(conn, [operation]) == [
             %{
               "operation_id" => operation["operation_id"],
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
           ]
  end

  defp snapshot do
    {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation), Repo.all(Operation)}
  end

  defp encode_ordered(value, direction) when is_map(value) do
    entries = value |> Enum.sort_by(&elem(&1, 0), direction)

    "{" <>
      Enum.map_join(entries, ",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> encode_ordered(value, direction)
      end) <> "}"
  end

  defp encode_ordered(value, direction) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &encode_ordered(&1, direction)) <> "]"

  defp encode_ordered(value, _direction), do: Jason.encode!(value)
end
