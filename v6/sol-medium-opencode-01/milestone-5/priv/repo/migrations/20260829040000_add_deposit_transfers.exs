defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :position, :integer
    end

    alter table(:payment_dispositions) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create table(:payment_settlements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :payment_disposition_id,
          references(:payment_dispositions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:payment_settlements, [:payment_disposition_id, :group_id])

    execute(&backfill_allocation_positions/0)
    execute(&backfill_payment_settlements/0)

    create index(:cash_allocations, [:payment_disposition_id, :position])
    create index(:credit_allocations, [:position])
  end

  def down do
    drop index(:credit_allocations, [:position])
    drop index(:cash_allocations, [:payment_disposition_id, :position])
    drop table(:payment_settlements)

    alter table(:payment_dispositions) do
      remove :participated_in_transfer
    end

    alter table(:cash_allocations) do
      remove :position
    end
  end

  defp backfill_allocation_positions do
    repo = repo()

    cash =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT cash.id, cash.room_id, operations.id
        FROM cash_allocations AS cash
        LEFT JOIN payment_dispositions AS payment ON payment.id = cash.payment_disposition_id
        LEFT JOIN partner_operations AS operations
          ON operations.operation_id = payment.payment_operation_id
        """,
        []
      ).rows
      |> Enum.map(fn [id, room_id, operation_order] ->
        {:cash, id, room_id, operation_order || -2, 0}
      end)

    credit =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT credit.id, credit.room_id, operations.id, credit.position
        FROM credit_allocations AS credit
        LEFT JOIN partner_operations AS operations
          ON operations.operation_id = credit.application_operation_id
        """,
        []
      ).rows
      |> Enum.map(fn [id, room_id, operation_order, old_position] ->
        {:credit, id, room_id, operation_order || -1, old_position || 0}
      end)

    room_positions =
      Ecto.Adapters.SQL.query!(repo, "SELECT id, position FROM rooms", []).rows
      |> Map.new(fn [id, position] -> {id, position} end)

    (cash ++ credit)
    |> Enum.sort_by(fn {kind, id, room_id, operation_order, old_position} ->
      {operation_order, old_position, Map.fetch!(room_positions, room_id), kind, id}
    end)
    |> Enum.with_index(1)
    |> Enum.each(fn
      {{:cash, id, _room_id, _operation_order, _old_position}, position} ->
        Ecto.Adapters.SQL.query!(
          repo,
          "UPDATE cash_allocations SET position = ? WHERE id = ?",
          [position, id]
        )

      {{:credit, id, _room_id, _operation_order, _old_position}, position} ->
        Ecto.Adapters.SQL.query!(
          repo,
          "UPDATE credit_allocations SET position = ? WHERE id = ?",
          [position, id]
        )
    end)
  end

  defp backfill_payment_settlements do
    repo = repo()

    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT id, group_id, refunded_cents, retained_cents, converted_cents
      FROM payment_dispositions
      WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_cents > 0
      """,
      []
    ).rows
    |> Enum.each(fn [payment_id, group_id, refunded, retained, converted] ->
      Ecto.Adapters.SQL.query!(
        repo,
        """
        INSERT INTO payment_settlements (
          id, payment_disposition_id, group_id, refunded_cents, retained_cents,
          converted_cents, inserted_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """,
        [Ecto.UUID.generate(), payment_id, group_id, refunded, retained, converted]
      )
    end)
  end
end
