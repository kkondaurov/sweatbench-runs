defmodule GroupStay.Groups.FundingAllocationOrder do
  @moduledoc false

  use Ecto.Schema

  schema "funding_allocation_orders" do
    timestamps(type: :utc_datetime)
  end
end
