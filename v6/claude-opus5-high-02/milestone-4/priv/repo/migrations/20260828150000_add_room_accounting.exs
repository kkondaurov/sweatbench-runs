defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  alias GroupStay.Reservations.Backfill

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    # Credit is redeemed into one room at a time, and a chargeback can take back entitlement the
    # lot no longer holds, which a returning amount then absorbs.
    alter table(:credit_applications) do
      add :room_id, references(:rooms, on_delete: :delete_all)
      add :absorbed_cents, :integer, null: false, default: 0
    end

    create index(:credit_applications, [:room_id])
    create index(:credit_applications, [:credit_lot_id])

    # Where every recorded cent currently sits. The autoincrementing primary key preserves the
    # order the rooms were filled in, which is the order a reduction unwinds.
    create table(:cash_allocations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :converted_lot_id, references(:credit_lots, on_delete: :nilify_all)
      add :amount_cents, :integer, null: false
      add :status, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:payment_operation_id])
    create index(:cash_allocations, [:converted_lot_id])

    flush()

    Backfill.run(settled_dispositions())

    # A group's settlement totals are now the sum of what became of each room's cash.
    alter table(:groups) do
      remove :cash_refunded_cents
      remove :cash_retained_cents
      remove :cash_converted_to_credit_cents
    end
  end

  def down do
    alter table(:groups) do
      add :cash_refunded_cents, :integer, null: false, default: 0
      add :cash_retained_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    flush()

    for {column, status} <- [
          {"cash_refunded_cents", "refunded"},
          {"cash_retained_cents", "retained"},
          {"cash_converted_to_credit_cents", "converted"}
        ] do
      execute("""
      UPDATE groups SET #{column} = (
        SELECT COALESCE(SUM(amount_cents), 0) FROM cash_allocations
        WHERE cash_allocations.group_id = groups.id AND status = '#{status}'
      )
      """)
    end

    # Without rooms to settle one at a time, a group's totals describe every room it holds again.
    execute("""
    UPDATE groups SET
      lodging_total_cents = (
        SELECT COALESCE(SUM(lodging_cents), 0) FROM rooms WHERE rooms.group_id = groups.id
      ),
      deposit_due_cents = (
        SELECT COALESCE(SUM(deposit_cents), 0) FROM rooms WHERE rooms.group_id = groups.id
      ),
      cash_paid_cents = (
        SELECT COALESCE(SUM(amount_cents), 0) FROM cash_allocations
        WHERE cash_allocations.group_id = groups.id
      ),
      credit_paid_cents = (
        SELECT COALESCE(SUM(amount_cents), 0) FROM credit_applications
        WHERE credit_applications.group_id = groups.id
      )
    """)

    drop table(:cash_allocations)

    drop index(:credit_applications, [:room_id])
    drop index(:credit_applications, [:credit_lot_id])

    alter table(:credit_applications) do
      remove :room_id
      remove :absorbed_cents
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :status
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end

  # A cancelled group settled all of its cash the same way, so which way is all the backfill needs
  # to classify the allocations it lays out.
  defp settled_dispositions do
    %{rows: rows} =
      repo().query!("""
      SELECT id, cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents
      FROM groups WHERE status = 'cancelled'
      """)

    for [id, refunded, retained, converted] <- rows, into: %{} do
      {id, disposition(refunded, retained, converted)}
    end
  end

  defp disposition(refunded, _retained, _converted) when refunded > 0, do: "refunded"
  defp disposition(_refunded, _retained, converted) when converted > 0, do: "converted"
  defp disposition(_refunded, _retained, _converted), do: "retained"
end
