defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  @moduledoc """
  Deposit transfers (docs/requests/05).

  Transfers draw from the source group's cash allocations and credit
  applications together, most recently created first, regardless of funding
  kind. To order rows across both tables, each allocation table gains a
  `seq` integer that the application assigns from one shared sequence
  (max over both tables, plus one). The backfill joins existing rows into
  that shared sequence deterministically: cash first (by row id), then
  credit (by rowid).

  A payment's statement grows `held_by_group` once any of its cash has
  moved through a transfer, so `payment_dispositions` tracks that
  participation with a `transferred` flag; the transfer operation flips it
  on the funding payment it moved.
  """
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :seq, :integer
    end

    alter table(:credit_applications) do
      add :seq, :integer
    end

    alter table(:payment_dispositions) do
      add :transferred, :boolean, null: false, default: false
    end

    flush()

    # Cash rows first, ordered by their integer row id, then credit rows
    # ordered by their SQLite rowid. Together they form one gapless shared
    # sequence so later transfers order allocations across both tables.
    execute """
    UPDATE cash_allocations
    SET seq = (SELECT COUNT(*) FROM cash_allocations c WHERE c.id < cash_allocations.id) + 1
    """

    execute """
    UPDATE credit_applications
    SET seq = (SELECT COUNT(*) FROM cash_allocations) +
              (SELECT COUNT(*) FROM credit_applications c WHERE c.rowid < credit_applications.rowid) + 1
    """
  end

  def down do
    alter table(:payment_dispositions) do
      remove :transferred
    end

    alter table(:credit_applications) do
      remove :seq
    end

    alter table(:cash_allocations) do
      remove :seq
    end
  end
end
