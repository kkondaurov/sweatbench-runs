defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_payments) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    alter table(:cash_room_allocations) do
      add :allocation_sequence, :integer, null: false, default: 0
    end

    alter table(:room_credit_allocations) do
      add :allocation_sequence, :integer, null: false, default: 0
    end

    create table(:cash_payment_dispositions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :cash_payment_id,
          references(:cash_payments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :reservation_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_payment_dispositions, [:cash_payment_id])
    create index(:cash_payment_dispositions, [:reservation_id])

    # Durable operation commit order is the best historical ordering retained
    # by the preceding release. The new writes below use one shared sequence
    # across cash and credit allocations so future transfers have an exact,
    # cross-kind reverse allocation order.
    execute("""
    UPDATE cash_room_allocations
    SET allocation_sequence =
      COALESCE((
        SELECT operation.id
        FROM cash_payments payment
        LEFT JOIN partner_operations operation
          ON operation.operation_id = payment.payment_operation_id
        WHERE payment.id = cash_room_allocations.cash_payment_id
      ), 0) * 1000000000 + rowid * 2
    """)

    execute("""
    UPDATE room_credit_allocations
    SET allocation_sequence =
      COALESCE((
        SELECT operation.id
        FROM credit_applications application
        LEFT JOIN partner_operations operation
          ON operation.operation_id = application.source_operation_id
        WHERE application.id = room_credit_allocations.credit_application_id
      ), 0) * 1000000000 + rowid * 2 + 1
    """)

    # Before transfers existed, every settlement belonged to the payment's
    # original group. Preserve that fact explicitly so a future chargeback can
    # reclassify group-level settlement totals after payments begin moving.
    for {kind, field} <- [
          {"refunded", "refunded_cents"},
          {"retained", "retained_cents"},
          {"converted", "converted_to_credit_cents"}
        ] do
      execute("""
      INSERT INTO cash_payment_dispositions
        (id, cash_payment_id, reservation_id, kind, amount_cents, inserted_at, updated_at)
      SELECT lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-' ||
             lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' ||
             lower(hex(randomblob(6))),
             id, reservation_id, '#{kind}', #{field}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM cash_payments
      WHERE #{field} > 0
      """)
    end
  end

  def down do
    drop table(:cash_payment_dispositions)

    alter table(:room_credit_allocations) do
      remove :allocation_sequence
    end

    alter table(:cash_room_allocations) do
      remove :allocation_sequence
    end

    alter table(:cash_payments) do
      remove :participated_in_transfer
    end
  end
end
