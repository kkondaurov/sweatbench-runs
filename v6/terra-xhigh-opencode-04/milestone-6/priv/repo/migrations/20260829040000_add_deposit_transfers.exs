defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_payments) do
      add :has_transferred, :boolean, null: false, default: false
    end

    alter table(:credit_applications) do
      add :allocation_order, :integer, null: false, default: 0
    end

    flush()

    # Credit applications created before transfers had no shared allocation sequence.
    # Place them after the existing cash sequence so later transfers remain deterministic.
    execute("""
    UPDATE credit_applications
    SET allocation_order = (SELECT COALESCE(MAX(fill_order), 0) FROM cash_room_allocations) + rowid
    WHERE allocation_order = 0
    """)
  end

  def down do
    alter table(:credit_applications) do
      remove :allocation_order
    end

    alter table(:cash_payments) do
      remove :has_transferred
    end
  end
end
