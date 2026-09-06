defmodule GroupStay.Deposits.CreditApplication do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_applications" do
    belongs_to :group, GroupStay.Deposits.Group
    belongs_to :credit_lot, GroupStay.Deposits.CreditLot
    belongs_to :room, GroupStay.Deposits.Room
    field :amount_cents, :integer
    field :fill_seq, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:group_id, :credit_lot_id, :room_id, :amount_cents, :fill_seq])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents, :fill_seq])
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:credit_lot_id)
  end
end
