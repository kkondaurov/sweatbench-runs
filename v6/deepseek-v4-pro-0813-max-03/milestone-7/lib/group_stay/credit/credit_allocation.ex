defmodule GroupStay.Credit.CreditAllocation do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group

  schema "credit_allocations" do
    field :amount_cents, :integer

    belongs_to :group, Group
    belongs_to :lot, CreditLot

    timestamps()
  end
end
