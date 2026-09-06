defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
      # Groups created by this release have room allocations from the start;
      # groups carried over from an earlier release have their pre-existing
      # funding materialized into room allocations lazily, on first touch.
      add :allocations_initialized, :boolean, null: false, default: false
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_applications) do
      add :position, :integer, null: false, default: 0
    end

    create table(:room_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false

      add :kind, :string, null: false
      # The operation that funded the deposit; nil for funding carried over
      # from before durable operation records existed.
      add :source_operation_id, :string
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all)
      add :amount_cents, :integer, null: false
      # The disposition of this funding: held on an active room, or settled by
      # a cancellation, reduction, or chargeback.
      add :state, :string, null: false, default: "held"
      # Position within the group's fill order.
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:source_operation_id])

    # Backfill the room-level accounting for rooms created by earlier
    # releases: rooms of cancelled groups are cancelled, and every room keeps
    # the deposit its rate plan implied when the group was opened.
    execute(backfill_room_status(), "")
    execute(backfill_room_deposits(), "")
    # Credit applications keep their original consumption order so funding
    # carried over from earlier releases can be reconstructed lot by lot.
    execute(backfill_application_positions(), "")
  end

  defp backfill_room_status do
    """
    UPDATE rooms SET status = 'cancelled'
    WHERE group_id IN (SELECT id FROM groups WHERE status = 'cancelled')
    """
  end

  defp backfill_room_deposits do
    """
    UPDATE rooms SET deposit_due_cents = (
      SELECT CASE g.rate_plan
        WHEN 'advance_purchase' THEN
          CAST(julianday(g.departure_on) - julianday(g.arrival_on) AS INTEGER)
            * rooms.nightly_rate_cents
        ELSE
          (40 * CAST(julianday(g.departure_on) - julianday(g.arrival_on) AS INTEGER)
            * rooms.nightly_rate_cents + 100) / 200
      END
      FROM groups g WHERE g.id = rooms.group_id
    )
    """
  end

  defp backfill_application_positions do
    """
    WITH ordered AS (
      SELECT a.id AS app_id,
             ROW_NUMBER() OVER (
               PARTITION BY a.group_id
               ORDER BY a.inserted_at, l.expires_on, l.source_operation_id, a.id
             ) - 1 AS rn
      FROM credit_applications a
      JOIN credit_lots l ON l.id = a.credit_lot_id
    )
    UPDATE credit_applications
    SET position = (SELECT rn FROM ordered WHERE ordered.app_id = credit_applications.id)
    """
  end
end
