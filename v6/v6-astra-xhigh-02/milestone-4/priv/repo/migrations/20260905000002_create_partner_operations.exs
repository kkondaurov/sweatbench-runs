defmodule GroupStay.Repo.Migrations.CreatePartnerOperations do
  use Ecto.Migration

  def change do
    # SQLite serializes writers. This generated integer id therefore records the
    # order of first commits, including rejections, without relying on a clock.
    create table(:partner_operations) do
      add :operation_id, :string, null: false
      add :type, :string
      add :payload, :map, null: false
      add :result, :map, null: false
    end

    create unique_index(:partner_operations, [:operation_id])
  end
end
