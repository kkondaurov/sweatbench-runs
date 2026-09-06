defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query
  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Repo}

  defp opening(id \\ "group", attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{id}",
        "type" => "open_group",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-03",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "a", "nightly_rate_cents" => 10000},
          %{"room_id" => "b", "nightly_rate_cents" => 5000}
        ]
      },
      attrs
    )
  end

  defp op(id, type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "group_id" => "group",
        "occurred_on" => "2027-01-02"
      },
      attrs
    )
  end

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp batch(operations),
    do: post_batch(operations) |> json_response(200) |> Map.fetch!("results")

  defp records, do: Repo.all(from o in Operation, order_by: o.id)
  defp domain, do: {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation)}

  defp stored(id) do
    build_conn() |> get(~p"/api/v1/operations/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  test "every operation replays its original result in a batch and after later state changes" do
    operations = [
      opening(),
      op("pay", "record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
      op("move", "reschedule_group", %{"new_arrival_on" => "2028-06-01"}),
      op("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("target"),
      op("apply", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 100}),
      op("restore", "cancel_group", %{"group_id" => "target", "refund_method" => "hotel_credit"})
    ]

    results = batch(operations ++ operations)
    {original, repeated} = Enum.split(results, length(operations))
    assert original == repeated
    assert Enum.all?(original, &(&1["status"] == "applied"))
    assert Enum.map(original, & &1["revision"]) == [1, 2, 3, 4, 1, 2, 3]
    before = domain()
    assert batch(operations) == original
    assert domain() == before

    for {operation, result} <- Enum.zip(operations, original) do
      assert stored(operation["operation_id"]) == result
    end

    assert Enum.map(records(), & &1.payload) == operations
    assert Enum.map(records(), & &1.result) == original
    assert Enum.map(records(), & &1.type) == Enum.map(operations, & &1["type"])
    assert Repo.one(CreditLot).remaining_cents == 110

    # Transactional DDL is restored by ConnCase's sandbox. Removing the domain
    # tables proves that replay and result lookup do not consult any domain state.
    for table <- ~w(credit_allocations credit_lots groups), do: Repo.query!("DROP TABLE #{table}")
    assert batch(operations) == original
    for result <- original, do: assert(stored(result["operation_id"]) == result)
  end

  test "cash refunds and non-refundable settlements are not repeated" do
    for {id, on, refunded, retained} <- [
          {"refundable", "2027-05-02", 100, 0},
          {"late", "2027-05-03", 0, 100}
        ] do
      batch([
        opening(id),
        op("pay-#{id}", "record_cash_payment", %{"group_id" => id, "amount_cents" => 100})
      ])

      cancel = op("cancel-#{id}", "cancel_group", %{"group_id" => id, "occurred_on" => on})

      assert [%{"refunded_cents" => ^refunded, "retained_cents" => ^retained}] =
               original = batch([cancel])

      before = domain()
      assert batch([cancel, cancel]) == original ++ original
      assert domain() == before
    end

    assert %{cash_refunded_cents: 100, cash_retained_cents: 100, cash_held_cents: 0} =
             GroupStay.Reservations.ledger()
  end

  test "rejections survive changes that would make them valid and corrected payloads conflict" do
    missing = op("missing", "record_cash_payment", %{"amount_cents" => 50})
    [missing_result] = batch([missing])
    assert missing_result["code"] == "group_not_found"
    batch([opening()])
    stale = op("stale", "record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 0})
    [stale_result] = batch([stale])
    assert stale_result["actual_revision"] == 1
    batch([op("pay", "record_cash_payment", %{"amount_cents" => 50})])
    before = domain()

    assert batch([missing, stale]) == [missing_result, stale_result]

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.merge(stale, %{"expected_revision" => 2, "amount_cents" => 10})])

    assert stored("stale") == stale_result
    assert stored("missing") == missing_result
    assert domain() == before
    assert Enum.map(records(), & &1.operation_id) == ["missing", "open-group", "stale", "pay"]
  end

  test "unknown types and incomplete submissions retain their entire original content" do
    submissions = [
      %{"operation_id" => "unknown", "type" => "future", "extra" => [nil, true, %{"x" => 1}]},
      %{"operation_id" => "incomplete", "type" => "open_group", "group_id" => "g"},
      %{"operation_id" => "no-type", "extra" => %{"nested" => ["a", 2.5]}},
      %{"operation_id" => "bad-type", "type" => ["open_group"]}
    ]

    results = batch(submissions)
    assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
    assert batch(submissions) == results
    assert Enum.map(records(), & &1.payload) === submissions
    assert domain() == {[], [], []}
    assert batch([opening()]) |> hd() |> Map.fetch!("status") == "applied"
  end

  test "invalid identifiers reject without creating a retry namespace" do
    invalid = [nil, [], false, %{}, %{"operation_id" => ""}, %{"operation_id" => 12}]
    assert Enum.all?(batch(invalid), &(&1["code"] == "invalid_operation"))
    assert records() == []
  end

  # Encode in explicitly different orders at every object level, including objects in arrays.
  defp ordered_json(value, order) when is_map(value) do
    pairs =
      value
      |> Enum.sort(order)
      |> Enum.map(fn {k, v} -> Jason.encode!(k) <> ":" <> ordered_json(v, order) end)

    "{" <> Enum.join(pairs, ",") <> "}"
  end

  defp ordered_json(value, order) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &ordered_json(&1, order)) <> "]"

  defp ordered_json(value, _), do: Jason.encode!(value)

  test "object key order is irrelevant but arrays, values, types and unknown fields matter" do
    operation =
      opening("group", %{"metadata" => %{"z" => [1, %{"x" => false, "a" => nil}], "a" => "text"}})

    results =
      for order <- [:asc, :desc] do
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/partner-batches", ordered_json(%{"operations" => [operation]}, order))
        |> json_response(200)
        |> Map.fetch!("results")
      end

    assert hd(results) == List.last(results)
    original_record = hd(records())
    before = domain()

    variants = [
      Map.put(operation, "rooms", Enum.reverse(operation["rooms"])),
      put_in(operation, ["metadata", "z"], [1.0, %{"x" => false, "a" => nil}]),
      put_in(operation, ["metadata", "a"], "changed"),
      Map.put(operation, "extra", nil),
      Map.delete(operation, "metadata"),
      Map.put(operation, "expected_revision", 1),
      Map.put(operation, "group_id", "another"),
      Map.put(operation, "type", "cancel_group")
    ]

    assert Enum.all?(batch(variants), &(&1["code"] == "operation_id_conflict"))
    assert records() == [original_record]
    assert domain() == before
    assert batch([operation]) == hd(results)
  end

  test "remembered insufficient credit and refund-method rejections retain revision precedence" do
    batch([opening()])
    credit = op("credit", "apply_hotel_credit", %{"amount_cents" => 10, "expected_revision" => 1})

    cancel =
      op("cancel", "cancel_group", %{
        "refund_method" => "hotel_credit",
        "occurred_on" => "2027-05-20"
      })

    [credit_result, cancel_result] = batch([credit, cancel])
    assert credit_result["code"] == "insufficient_credit"
    assert cancel_result["code"] == "refund_method_not_available"

    batch([
      opening("source"),
      op("pay-source", "record_cash_payment", %{"group_id" => "source", "amount_cents" => 100}),
      op("cancel-source", "cancel_group", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      op("move", "reschedule_group", %{"new_arrival_on" => "2028-06-01"})
    ])

    before = domain()
    assert batch([credit, cancel]) == [credit_result, cancel_result]
    assert domain() == before
  end

  test "audit ordering follows first commits, including rejections, across batches" do
    first = op("Z-last-alphabetically", "cancel_group")
    second = opening()
    third = op("A-first-alphabetically", "record_cash_payment", %{"amount_cents" => 10})
    [rejected, applied] = batch([first, second, first]) |> Enum.take(2)
    [paid] = batch([third, second, Map.put(first, "type", "other")]) |> Enum.take(1)

    assert Enum.map(records(), & &1.operation_id) == [
             first["operation_id"],
             second["operation_id"],
             third["operation_id"]
           ]

    assert Enum.map(records(), & &1.result) == [rejected, applied, paid]

    assert build_conn() |> get(~p"/api/v1/operations/absent") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  test "unexpected persistence faults roll back all current writes, return 500 and stop the batch" do
    opening = opening()
    payment = op("pay", "record_cash_payment", %{"amount_cents" => 100})
    cancel = op("fault", "cancel_group", %{"refund_method" => "hotel_credit"})
    later = opening("later")

    Repo.query!("""
    CREATE TRIGGER fail_operation BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected persistence failure'); END
    """)

    assert_error_sent 500, fn -> post_batch([opening, payment, cancel, later]) end
    assert Repo.get(Group, "group").revision == 2
    assert Repo.get(Group, "group").cash_paid_cents == 100
    assert Repo.get(Group, "later") == nil
    assert Repo.all(CreditLot) == []
    assert Repo.all(CreditAllocation) == []
    assert Enum.map(records(), & &1.operation_id) == ["open-group", "pay"]
    assert GroupStay.Reservations.get_operation("fault") == nil

    Repo.query!("DROP TRIGGER fail_operation")
    results = batch([opening, payment, cancel, later])
    assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 1]
    assert Repo.one(CreditLot).remaining_cents == 110
    assert batch([opening, payment, cancel, later]) == results
    assert length(records()) == 4
  end
end
