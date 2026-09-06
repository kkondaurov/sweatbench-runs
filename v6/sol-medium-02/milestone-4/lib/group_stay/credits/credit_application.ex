defmodule GroupStay.Credits.CreditApplication do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credits.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room

  schema "credit_applications" do
    belongs_to :group, Group
    belongs_to :credit_lot, CreditLot
    belongs_to :room, Room
    field :amount_cents, :integer
    field :operation_id, :string
    field :status, :string, default: "active"
    field :position, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [
      :group_id,
      :credit_lot_id,
      :room_id,
      :amount_cents,
      :operation_id,
      :status,
      :position
    ])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents, :status])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_inclusion(:status, ["active", "restored", "consumed", "settled"])
  end
end
