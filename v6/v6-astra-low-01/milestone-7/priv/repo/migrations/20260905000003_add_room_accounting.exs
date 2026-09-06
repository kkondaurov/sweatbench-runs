defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :funding, {:array, :map}, null: false, default: []
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :entitlements, :map, null: false, default: %{}
      add :unrecovered_cents, :integer, null: false, default: 0
    end

    flush()
    GroupStay.Accounting.upgrade(repo())
  end

  def down do
    alter table(:groups) do
      remove :funding
      remove :reduced_cents
      remove :charged_back_cents
    end

    alter table(:credit_lots) do
      remove :entitlements
      remove :unrecovered_cents
    end
  end
end
