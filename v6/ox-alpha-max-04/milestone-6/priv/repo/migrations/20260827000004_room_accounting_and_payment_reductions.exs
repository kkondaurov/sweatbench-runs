defmodule GroupStay.Repo.Migrations.RoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def change do
    # Room-level accounting: every room carries its own settlement status.
    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
    end

    # Groups cancelled by an earlier release settled all of their rooms.
    execute(
      """
      UPDATE group_rooms
      SET status = 'cancelled'
      WHERE group_id IN (SELECT id FROM groups WHERE status = 'cancelled')
      """,
      ""
    )

    # Credit applications become attributable: which applying operation and
    # which room's deposit they fund. Pre-existing rows keep nil for both and
    # form the unattributed senior block of their group.
    alter table(:group_credit_applications) do
      add :operation_id, :string
      add :room_id, references(:group_rooms, type: :binary_id, on_delete: :delete_all)
    end

    create index(:group_credit_applications, [:room_id])

    # Clawing back a payment's credit entitlement leaves an unrecovered
    # remainder on the lot until later restorations absorb it.
    alter table(:credit_lots) do
      add :clawback_unrecovered_cents, :integer, null: false, default: 0
    end
  end
end
