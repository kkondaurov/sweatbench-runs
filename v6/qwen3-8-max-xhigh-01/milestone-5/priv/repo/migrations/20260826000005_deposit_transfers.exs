defmodule GroupStay.Repo.Migrations.DepositTransfers do
  use Ecto.Migration

  alias GroupStay.Migrations.Request05

  def up do
    alter table(:cash_payments) do
      add :has_transfers, :boolean, null: false, default: false
    end

    alter table(:cash_allocations) do
      add :global_seq, :integer, null: false, default: 0
    end

    flush()

    Request05.run()
  end

  def down do
    alter table(:cash_payments) do
      remove :has_transfers
    end

    alter table(:cash_allocations) do
      remove :global_seq
    end
  end
end
