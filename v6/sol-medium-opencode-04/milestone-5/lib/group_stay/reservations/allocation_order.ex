defmodule GroupStay.Reservations.AllocationOrder do
  use Ecto.Schema
  import Ecto.Changeset

  schema "allocation_orders" do
    field :kind, :string
    field :allocation_id, :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(order, attrs) do
    order
    |> cast(attrs, [:kind, :allocation_id])
    |> validate_required([:kind, :allocation_id])
    |> unique_constraint([:kind, :allocation_id])
  end
end
