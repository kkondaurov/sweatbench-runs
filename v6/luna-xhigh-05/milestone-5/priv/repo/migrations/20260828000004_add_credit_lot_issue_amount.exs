defmodule GroupStay.Repo.Migrations.AddCreditLotIssueAmount do
  use Ecto.Migration

  def change do
    alter table(:hotel_credit_lots) do
      add :issued_cents, :integer, null: false, default: 0
    end
  end
end
