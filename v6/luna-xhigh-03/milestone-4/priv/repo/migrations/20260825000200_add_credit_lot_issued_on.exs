defmodule GroupStay.Repo.Migrations.AddCreditLotIssuedOn do
  use Ecto.Migration

  def up do
    alter table(:credit_lots) do
      add :issued_on, :date
    end

    execute "UPDATE credit_lots SET issued_on = date(expires_on, '-365 days') WHERE issued_on IS NULL"
  end

  def down do
    alter table(:credit_lots) do
      remove :issued_on
    end
  end
end
