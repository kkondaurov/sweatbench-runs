defmodule GroupStay.Deposits.LedgerEntry do
  use Ecto.Schema

  import Ecto.Changeset

  @kinds ~w(cash refund retain convert_to_credit reduce_cash charge_back_cash)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ledger_entries" do
    belongs_to :group, GroupStay.Deposits.Group
    field :kind, :string
    field :amount_cents, :integer
    field :occurred_on, :date
    field :operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:group_id, :kind, :amount_cents, :occurred_on, :operation_id])
    |> validate_required([:group_id, :kind, :amount_cents, :occurred_on])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:group_id)
  end
end
