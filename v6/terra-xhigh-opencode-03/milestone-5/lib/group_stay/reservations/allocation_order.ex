defmodule GroupStay.Reservations.AllocationOrder do
  use Ecto.Schema
  import Ecto.Changeset

  schema "allocation_orders" do
    field :allocation_type, :string
    field :allocation_db_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation_order, attrs) do
    allocation_order
    |> cast(attrs, [:allocation_type, :allocation_db_id])
    |> validate_required([:allocation_type, :allocation_db_id])
    |> validate_inclusion(:allocation_type, ["cash", "credit"])
    |> unique_constraint([:allocation_type, :allocation_db_id])
  end
end
