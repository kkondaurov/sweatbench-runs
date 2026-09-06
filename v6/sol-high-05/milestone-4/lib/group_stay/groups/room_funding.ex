defmodule GroupStay.Groups.RoomFunding do
  use Ecto.Schema
  import Ecto.Changeset

  schema "room_fundings" do
    field :room_id, :string
    field :funding_type, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    belongs_to :credit_lot, GroupStay.Groups.CreditLot
    belongs_to :group, GroupStay.Groups.Group, references: :group_id, type: :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @fields ~w(group_id room_id funding_type payment_operation_id credit_lot_id amount_cents)a

  def changeset(funding, attrs) do
    funding
    |> cast(attrs, @fields)
    |> validate_required([:group_id, :room_id, :funding_type, :amount_cents])
    |> validate_inclusion(:funding_type, ["cash", "credit"])
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:credit_lot_id)
  end
end
