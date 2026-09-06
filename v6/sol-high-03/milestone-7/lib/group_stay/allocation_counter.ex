defmodule GroupStay.AllocationCounter do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "allocation_counters" do
    field :last_value, :integer
  end
end
