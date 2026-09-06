defmodule GroupStay.Repo.Migrations.DepositTransfers do
  use Ecto.Migration

  def up do
    # Orders every cash allocation by creation across all groups, so
    # reductions and chargebacks can remove a payment's held allocations in
    # reverse allocation order even after transfers spread them between
    # groups. Existing rows take their physical insertion order.
    alter table(:cash_allocations) do
      add :creation_seq, :integer
    end

    # Marks payments whose funding ever moved through a transfer; their
    # statements evolve to break held cash down by group.
    alter table(:payment_cash_dispositions) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    execute("""
    UPDATE cash_allocations SET creation_seq = (
      SELECT COUNT(*) FROM cash_allocations AS earlier
      WHERE earlier.rowid <= cash_allocations.rowid
    )
    """)
  end

  def down do
    alter table(:payment_cash_dispositions) do
      remove :participated_in_transfer
    end

    alter table(:cash_allocations) do
      remove :creation_seq
    end
  end
end
