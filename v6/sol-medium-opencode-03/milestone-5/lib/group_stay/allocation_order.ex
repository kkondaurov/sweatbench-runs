defmodule GroupStay.AllocationOrder do
  use Ecto.Schema

  schema "allocation_orders" do
    timestamps(type: :utc_datetime)
  end
end
