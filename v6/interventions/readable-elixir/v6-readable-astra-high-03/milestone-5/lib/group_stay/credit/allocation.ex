defmodule GroupStay.Credit.Allocation do
  @moduledoc """
  Credit from an original lot currently funding an active group. Allocated credit
  remains a liability even after its lot expires or its entitlement is revoked.
  Room funding slices provide the detailed distribution; this aggregate changes
  with those slices in the same transaction. Partial settlement reduces it, and
  final settlement removes it.
  """
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer
  end
end
