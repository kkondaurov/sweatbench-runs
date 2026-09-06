defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  @moduledoc """
  Tracks which cash payments have ever participated in a deposit transfer.

  A transfer moves held funding between groups without touching the ledger,
  so the durable evidence that a payment's cash now spans several groups is
  this marker. Once marked, a payment's reconciliation statement reports its
  held cash per group for the rest of its life — even after nothing remains
  held.
  """

  def change do
    create table(:transfer_participations) do
      add :operation_id, :text, null: false

      timestamps()
    end

    create unique_index(:transfer_participations, [:operation_id])
  end
end
