defmodule GroupStay.Repo.Migrations.CreatePartnerOperations do
  use Ecto.Migration

  def change do
    create table(:partner_operations) do
      add :operation_id, :string, null: false
      # The operation type as submitted. Structurally invalid operations
      # may not carry a usable type, so it stays nullable; the payload
      # retains the complete submitted content either way.
      add :type, :string
      # The complete submitted content as canonical JSON: object keys are
      # sorted recursively, so member order is insignificant, while array
      # order and every value are preserved.
      add :payload, :text, null: false
      # The exact result returned when the operation was first received.
      add :result, :text, null: false

      timestamps()
    end

    # The gateway's operation-identifier namespace starts with this
    # release, so no records are reconstructed for earlier releases. The
    # auto-incremented primary key preserves the order in which records
    # were first committed.
    create unique_index(:partner_operations, [:operation_id])
  end
end
