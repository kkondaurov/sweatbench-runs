defmodule GroupStay.Operations.JournalTest do
  use GroupStay.DataCase

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Operations.Journal
  alias GroupStay.Operations.Record

  defp count_records do
    Repo.aggregate(from(r in Record), :count, :seq)
  end

  test "commits the first outcome and replays it without running the operation again" do
    raw = %{"operation_id" => "op-1", "type" => "cancel_group", "group_id" => "g1"}

    assert %{status: "applied", amount: 1} =
             Journal.execute(raw, fn ->
               send(self(), :first_run)
               {%{status: "applied", amount: 1}, "cancel_group"}
             end)

    assert_received :first_run

    assert %{"status" => "applied", "amount" => 1} =
             Journal.execute(raw, fn ->
               send(self(), :second_run)
               flunk("a replay must not run the operation")
             end)

    refute_received :second_run
    assert count_records() == 1
  end

  test "rejects are remembered just like applied results" do
    raw = %{"operation_id" => "op-1", "type" => "cancel_group", "amount_cents" => -5}

    assert %{status: "rejected"} =
             Journal.execute(raw, fn -> {%{status: "rejected", code: "invalid_amount"}, nil} end)

    # A later attempt that would be valid still receives the stored rejection.
    assert %{"code" => "invalid_amount"} =
             Journal.execute(raw, fn -> {%{status: "applied"}, nil} end)

    record = Repo.get_by(Record, operation_id: "op-1")
    assert Jason.decode!(record.result)["code"] == "invalid_amount"
  end

  test "reusing an identifier with different content conflicts without replacing the record" do
    Journal.execute(%{"operation_id" => "op-1", "v" => 1}, fn ->
      {%{status: "applied"}, "cancel_group"}
    end)

    assert %{code: "operation_id_conflict", status: "rejected"} =
             Journal.execute(%{"operation_id" => "op-1", "v" => 2}, fn ->
               {%{status: "applied", replaced: true}, nil}
             end)

    assert count_records() == 1
    assert %{"status" => "applied"} = Journal.fetch_result("op-1")

    # The original payload still replays after the conflict.
    assert %{"status" => "applied"} =
             Journal.execute(%{"operation_id" => "op-1", "v" => 1}, fn ->
               flunk("must replay")
             end)
  end

  test "an unexpected exception rolls back and is not remembered" do
    raw = %{"operation_id" => "op-1", "type" => "cancel_group"}

    assert_raise RuntimeError, "boom", fn ->
      Journal.execute(raw, fn ->
        Repo.insert!(%Record{operation_id: "dirty", payload: "{}", result: "{}"})
        raise "boom"
      end)
    end

    assert count_records() == 0

    # The identifier is free again and a healthy run succeeds.
    assert %{status: "applied"} =
             Journal.execute(raw, fn -> {%{status: "applied"}, "cancel_group"} end)

    assert count_records() == 1
  end

  test "operations without a usable identifier run every time and are not recorded" do
    for raw <- [
          %{"type" => "cancel_group"},
          %{"operation_id" => ""},
          %{"operation_id" => 7}
        ] do
      assert %{runs: 1} = Journal.execute(raw, fn -> {%{runs: 1}, nil} end)
      assert %{runs: 2} = Journal.execute(raw, fn -> {%{runs: 2}, nil} end)
    end

    assert count_records() == 0
  end

  test "the operation_id unique violation is recognized as a lost insert race" do
    Repo.insert!(%Record{operation_id: "op-dupe", payload: "{}", result: "{}"})

    {:error, changeset} =
      Record.changeset(%Record{}, %{operation_id: "op-dupe", payload: "{}", result: "{}"})
      |> Repo.insert()

    assert Journal.lost_insert_race?(changeset)

    # Any other changeset error must not be mistaken for the race.
    bad = Record.changeset(%Record{operation_id: "op-dupe"}, %{result: "{}"})
    refute Journal.lost_insert_race?(bad)
  end

  test "records keep their commit order in seq" do
    for id <- ["op-c", "op-a", "op-b"] do
      Journal.execute(%{"operation_id" => id}, fn -> {%{id: id}, "cancel_group"} end)
    end

    ids =
      from(r in Record, order_by: r.seq, select: r.operation_id)
      |> Repo.all()

    assert ids == ["op-c", "op-a", "op-b"]
  end

  test "fetch_result returns nil for unknown identifiers" do
    assert Journal.fetch_result("op-nowhere") == nil
  end
end
