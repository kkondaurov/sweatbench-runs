defmodule GroupStay.Credit.CreditApplication do
  @moduledoc """
  Legacy funding record from before room-level allocations: how much of a
  credit lot funded an active group, in original consumption order. The table
  is migrated into `room_allocations` by the room-accounting migration and
  dropped afterward; this schema remains only so older migrations that read
  the table keep working.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :credit_lot, CreditLot
    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:amount_cents, :credit_lot_id, :group_id])
    |> validate_required([:amount_cents, :credit_lot_id, :group_id])
  end
end
