defmodule GroupStay.Deposits.LedgerEntry do
  use Ecto.Schema

  import Ecto.Changeset

  @kinds ~w(cash refund retain)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ledger_entries" do
    belongs_to :group, GroupStay.Deposits.Group
    field :kind, :string
    field :amount_cents, :integer
    field :occurred_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:group_id, :kind, :amount_cents, :occurred_on])
    |> validate_required([:group_id, :kind, :amount_cents, :occurred_on])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:group_id)
  end
end
