defmodule GroupStay.Ledger.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ledger_entries" do
    field :kind, :string
    field :amount_cents, :integer
    field :occurred_on, :date
    field :operation_id, :string

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:group_id, :kind, :amount_cents, :occurred_on, :operation_id])
    |> validate_required([:group_id, :kind, :amount_cents, :occurred_on, :operation_id])
  end
end
