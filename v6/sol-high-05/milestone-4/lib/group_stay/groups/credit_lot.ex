defmodule GroupStay.Groups.CreditLot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0
    field :expires_on, :date

    timestamps(type: :utc_datetime)
  end

  @fields ~w(guest_id source_operation_id remaining_cents unrecovered_clawback_cents expires_on)a

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
    |> validate_number(:unrecovered_clawback_cents, greater_than_or_equal_to: 0)
  end
end
