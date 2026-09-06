defmodule GroupStay.Reservations.CashEntry do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "cash_entries" do
    field :entry_type, :string
    field :amount_cents, :integer
    field :occurred_on, :date

    belongs_to :group, GroupStay.Reservations.Group
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:group_id, :entry_type, :amount_cents, :occurred_on])
    |> validate_required([:group_id, :entry_type, :amount_cents, :occurred_on])
  end
end
