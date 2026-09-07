defmodule GroupStay.OperationsMigrationTest do
  use GroupStay.CommittedRepoCase, async: false

  import GroupStay.MigrationHelpers
  import GroupStay.PartnerOperations

  alias GroupStay.{HotelCredit, LegacyAccounts, Operations, Repo, Reservations}
  alias GroupStay.HotelCredit.Lot
  alias GroupStay.Operations.Operation

  test "upgrading cancellation-era accounts preserves credit history without inventing audit records" do
    assert Ecto.Migrator.run(Repo, migrations(), :down, to: 20_260_907_000_002, log: false) == [
             20_260_907_000_005,
             20_260_907_000_004,
             20_260_907_000_003,
             20_260_907_000_002
           ]

    LegacyAccounts.group("group-81", %{
      deposit_paid_cents: 1_500,
      credit_paid_cents: 1_500,
      revision: 2
    })

    # Before durable operations, separate cancellations could share a reference.
    for {id, remaining, applied} <- [{"first", 0, 1_100}, {"second", 700, 400}] do
      LegacyAccounts.group(id, %{
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 1_000,
        cash_converted_to_credit_cents: 1_000,
        revision: 3
      })

      lot = LegacyAccounts.lot(id, "legacy-reference", 1_100, remaining)
      LegacyAccounts.application("group-81", lot, applied)
    end

    lots_before = LegacyAccounts.rows("credit_lots")
    applications_before = LegacyAccounts.rows("credit_applications")

    assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == [
             20_260_907_000_002,
             20_260_907_000_003,
             20_260_907_000_004,
             20_260_907_000_005
           ]

    assert Enum.map(
             LegacyAccounts.rows("credit_lots"),
             &Map.delete(&1, "unrecovered_clawback_cents")
           ) == lots_before

    assert LegacyAccounts.rows("credit_applications") == applications_before

    assert Enum.map(Repo.all(Lot), & &1.source_operation_id) ==
             List.duplicate("legacy-reference", 2)

    assert Repo.all(Operation) == []
    assert Operations.get_result("legacy-reference") == nil
    assert HotelCredit.balance("guest-22", ~D[2026-11-01]).available_cents == 700

    operation = payment(%{"operation_id" => "legacy-reference", "expected_revision" => 2})
    result = Operations.process(operation)
    assert result["revision"] == 3
    assert result["status"] == "applied"
    assert Operations.process(operation) == result
    assert Repo.aggregate(Operation, :count) == 1
    assert Reservations.get_group("group-81").deposit_paid_cents == 2_500
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 2_200
  end
end
