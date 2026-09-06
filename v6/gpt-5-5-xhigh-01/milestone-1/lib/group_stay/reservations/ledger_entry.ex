defmodule GroupStay.Reservations.LedgerEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ledger_entries" do
    field :operation_id, :string
    field :entry_type, :string
    field :amount_cents, :integer
    field :occurred_on, :date

    belongs_to :group, GroupStay.Reservations.Group

    timestamps(type: :utc_datetime)
  end

  def changeset(ledger_entry, attrs) do
    ledger_entry
    |> cast(attrs, [:group_id, :operation_id, :entry_type, :amount_cents, :occurred_on])
    |> validate_required([:group_id, :operation_id, :entry_type, :amount_cents, :occurred_on])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
