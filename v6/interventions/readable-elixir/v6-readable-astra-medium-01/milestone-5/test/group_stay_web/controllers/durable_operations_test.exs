defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query
  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Operations.Entry

  defp open(id \\ "open", group \\ "group") do
    %{
      "operation_id" => id,
      "type" => "open_group",
      "group_id" => group,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2027-01-01",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 10000},
        %{"room_id" => "b", "nightly_rate_cents" => 5000}
      ]
    }
  end

  defp op(id, type, attrs) do
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

  defp batch(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(id) do
    build_conn()
    |> get("/api/v1/operations/#{id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "whole batch retries replay every applied outcome, including dates, revisions and credit" do
    operations = [
      open(),
      op("pay", "record_cash_payment", %{"amount_cents" => 100}),
      op("move", "reschedule_group", %{"new_arrival_on" => "2027-07-01"}),
      op("cancel", "cancel_group", %{"refund_method" => "hotel_credit"}),
      open("target-open", "target"),
      op("redeem", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110}),
      op("restore", "cancel_group", %{"group_id" => "target"})
    ]

    results = batch(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    before =
      {Reservations.ledger(~D[2027-01-02]), GroupStay.Credits.available("guest", ~D[2027-01-02])}

    assert batch(operations) == results
    assert batch(operations ++ operations) == results ++ results

    assert {Reservations.ledger(~D[2027-01-02]),
            GroupStay.Credits.available("guest", ~D[2027-01-02])} == before

    assert Repo.aggregate(Entry, :count) == length(operations)

    for result <- results, do: assert(read(result["operation_id"]) == result)
    assert Reservations.get_group("group").revision == 4
    assert Reservations.get_group("target").revision == 3
  end

  test "rejections remain original after the group changes and conflicts never replace them" do
    missing = op("missing", "record_cash_payment", %{"amount_cents" => 100})
    [rejected, _, paid] = batch([missing, open(), Map.put(missing, "operation_id", "pay")])
    assert rejected["code"] == "group_not_found"
    assert paid["revision"] == 2
    assert batch([missing]) == [rejected]

    stale = op("stale", "record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 1})
    [original] = batch([stale])
    assert original["actual_revision"] == 2
    batch([op("later", "record_cash_payment", %{"amount_cents" => 100})])
    assert batch([stale]) == [original]
    assert read("stale") == original

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(stale, "expected_revision", 3)])

    assert read("stale") == original
    assert Reservations.get_group("group").revision == 3
  end

  test "equivalence ignores nested object order but includes arrays, types and extra content" do
    submission =
      Map.put(open(), "metadata", %{"b" => [1, true, nil], "a" => %{"z" => "x", "y" => 2}})

    [result] = batch([submission])

    # Submit actual JSON with reversed keys at every object level.
    response =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/v1/partner-batches",
        encode_reversed_keys(%{"operations" => [submission]})
      )
      |> json_response(200)

    assert response["results"] == [result]

    for changed <- [
          Map.update!(submission, "rooms", &Enum.reverse/1),
          put_in(submission, ["metadata", "b"], [true, 1, nil]),
          put_in(submission, ["metadata", "a", "y"], 2.0),
          Map.delete(submission, "metadata"),
          Map.put(submission, "type", "cancel_group")
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch([changed])
    end

    assert read("open") == result
    assert Repo.one!(Entry).submission === submission
  end

  test "audit retains complete rejected submissions and first commit order without retry entries" do
    malformed = %{
      "operation_id" => "z",
      "type" => ["unknown"],
      "extra" => %{"all" => [nil, false, 4]}
    }

    unknown = %{"operation_id" => "a", "type" => "unknown"}
    operations = [malformed, open(), unknown]
    results = batch(operations)
    assert hd(results)["code"] == "invalid_operation"
    assert List.last(results)["code"] == "invalid_operation"
    assert batch(operations) == results
    assert [%{"code" => "operation_id_conflict"}] = batch([Map.put(unknown, "extra", true)])

    entries = Repo.all(from e in Entry, order_by: e.id)
    assert Enum.map(entries, & &1.submission) == operations
    assert Enum.map(entries, & &1.result) == results
    assert Enum.map(entries, & &1.type) == [nil, "open_group", "unknown"]
    assert Enum.map(entries, & &1.operation_id) == ["z", "open", "a"]
    assert read("z") == hd(results)
  end

  test "unidentified operations reject independently and reads expose only results" do
    assert build_conn() |> get("/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}

    results = batch([nil, [], %{}, %{"operation_id" => ""}, %{"operation_id" => 12}, open()])
    assert Enum.all?(Enum.take(results, 5), &(&1["code"] == "invalid_operation"))
    assert Repo.aggregate(Entry, :count) == 1
    assert read("open") == List.last(results)
    assert Operations.get_result("missing") == nil
  end

  defp encode_reversed_keys(value) when is_map(value) do
    members =
      value
      |> Enum.sort(:desc)
      |> Enum.map_join(",", fn {key, child} ->
        Jason.encode!(key) <> ":" <> encode_reversed_keys(child)
      end)

    "{" <> members <> "}"
  end

  defp encode_reversed_keys(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &encode_reversed_keys/1) <> "]"

  defp encode_reversed_keys(value), do: Jason.encode!(value)
end
