defmodule GroupStay.Funding.AllocationOrder do
  @moduledoc """
  Supplies one sequence shared by cash and hotel-credit allocations.

  The sequence represents when funding was placed on its current room. Transfers create new
  sequence entries while preserving the cash payment or credit lot that supplied the funds. That
  makes reverse allocation order well-defined across both funding kinds and across groups.
  """

  use Ecto.Schema

  alias GroupStay.Repo

  schema "funding_allocation_orders" do
  end

  @spec next_id!() :: pos_integer()
  def next_id! do
    %__MODULE__{}
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
