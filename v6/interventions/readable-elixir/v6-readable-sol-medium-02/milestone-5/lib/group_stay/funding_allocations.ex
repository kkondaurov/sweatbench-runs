defmodule GroupStay.FundingAllocations do
  @moduledoc "Shared creation ordering for cash and hotel-credit room allocations."

  alias Ecto.Changeset
  alias GroupStay.Repo
  alias GroupStay.Reservations.FundingAllocationSequence

  @doc "Creates and returns the next allocation sequence identifier."
  def next_sequence_id! do
    %FundingAllocationSequence{}
    |> Changeset.change()
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
