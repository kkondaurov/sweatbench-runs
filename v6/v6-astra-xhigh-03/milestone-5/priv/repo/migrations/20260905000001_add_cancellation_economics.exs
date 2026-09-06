defmodule GroupStay.Repo.Migrations.AddCancellationEconomics do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :policy_version, :string,
        null: false,
        default: "flex-14",
        check: %{
          name: "valid_policy_version",
          expr: "policy_version IN ('flex-14', 'flex-30', 'advance-nonrefundable')"
        }

      add :credit_paid_cents, :integer,
        null: false,
        default: 0,
        check: %{
          name: "valid_credit_paid",
          expr: "credit_paid_cents >= 0 AND credit_paid_cents <= deposit_paid_cents"
        }

      add :cash_converted_to_credit_cents, :integer,
        null: false,
        default: 0,
        check: %{name: "valid_cash_converted", expr: "cash_converted_to_credit_cents >= 0"}
    end

    execute """
    UPDATE groups SET policy_version = CASE
      WHEN rate_plan = 'advance_purchase' THEN 'advance-nonrefundable'
      WHEN booked_on >= '2027-01-01' THEN 'flex-30'
      ELSE 'flex-14'
    END
    """

    create table(:credit_lots) do
      add :guest_id, :string, null: false
      add :source_operation_id, :string, null: false
      add :source_group_id, references(:groups, column: :group_id, type: :string), null: false
      add :expires_on, :date, null: false

      add :issued_cents, :integer,
        null: false,
        check: %{name: "valid_issued", expr: "issued_cents > 0"}

      add :remaining_cents, :integer,
        null: false,
        check: %{
          name: "valid_remaining",
          expr: "remaining_cents >= 0 AND remaining_cents <= issued_cents"
        }
    end

    create unique_index(:credit_lots, [:source_group_id])
    create index(:credit_lots, [:guest_id, :expires_on, :source_operation_id])

    create table(:credit_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :credit_lot_id, references(:credit_lots), null: false

      add :amount_cents, :integer,
        null: false,
        check: %{name: "valid_allocation", expr: "amount_cents > 0"}
    end

    create unique_index(:credit_allocations, [:group_id, :credit_lot_id])
  end

  def down do
    drop table(:credit_allocations)
    drop table(:credit_lots)

    alter table(:groups) do
      remove :cash_converted_to_credit_cents
      remove :credit_paid_cents
      remove :policy_version
    end
  end
end
