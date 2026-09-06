defmodule GroupStay.Repo.Migrations.CreatePartnerOperations do
  use Ecto.Migration

  def change do
    # The gateway starts a new operation-identifier namespace with this release, so nothing has to
    # be reconstructed for operations submitted under earlier ones: the table starts empty and the
    # idempotency guarantee begins with the first operation this release receives.
    create table(:partner_operations) do
      add :operation_id, :string, null: false
      add :type, :string
      add :payload, :text, null: false
      add :result, :text, null: false

      timestamps(type: :utc_datetime)
    end

    # One record per identifier, whatever else may race for it.
    create unique_index(:partner_operations, [:operation_id])
  end
end
