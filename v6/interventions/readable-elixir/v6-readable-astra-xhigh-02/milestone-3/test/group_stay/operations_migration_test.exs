defmodule GroupStay.OperationsMigrationTest do
  use GroupStay.CommittedRepoCase, async: false

  import GroupStay.MigrationHelpers
  import GroupStay.PartnerOperations

  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.HotelCredit.{Application, Lot}
  alias GroupStay.Operations.Operation
  alias GroupStay.Reservations.{Group, Room}

  test "upgrading cancellation-era accounts preserves credit history without inventing audit records" do
    assert Ecto.Migrator.run(Repo, migrations(), :down, step: 1, log: false) == [
             20_260_907_000_002
           ]

    # Before durable operations, separate cancellations could share a reference.
    # Apply through the domain layer to reproduce that release's persisted state.
    legacy_operations =
      Enum.flat_map(["first", "second"], fn id ->
        [
          open_group(%{"group_id" => id}),
          payment(%{"group_id" => id}),
          cancellation(%{
            "group_id" => id,
            "operation_id" => "legacy-reference",
            "refund_method" => "hotel_credit"
          })
        ]
      end) ++ [open_group(), credit_payment(%{"amount_cents" => 1_500})]

    for operation <- legacy_operations do
      assert {:ok, {:ok, _result}} =
               Repo.write_transaction(fn -> Reservations.apply_operation(operation) end)
    end

    before = snapshot()

    assert Enum.map(Repo.all(Lot), & &1.source_operation_id) ==
             List.duplicate("legacy-reference", 2)

    assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == [
             20_260_907_000_002
           ]

    assert snapshot() == before
    assert Repo.all(Operation) == []
    assert Operations.get_result("legacy-reference") == nil

    operation = payment(%{"operation_id" => "legacy-reference", "expected_revision" => 2})
    result = Operations.process(operation)
    assert result["revision"] == 3
    assert result["status"] == "applied"
    assert Operations.process(operation) == result
    assert Repo.aggregate(Operation, :count) == 1
    assert Reservations.get_group("group-81").deposit_paid_cents == 2_500
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 2_200
  end

  defp snapshot do
    {Repo.all(Group), Repo.all(Room), Repo.all(Lot), Repo.all(Application),
     Reservations.ledger(~D[2026-11-01])}
  end
end
