defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    # Marks that held funding from a cash payment has participated in a
    # deposit transfer, which switches its statement to the evolved shape.
    alter table(:cash_payments) do
      add :transferred, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:cash_payments) do
      remove :transferred
    end
  end
end
