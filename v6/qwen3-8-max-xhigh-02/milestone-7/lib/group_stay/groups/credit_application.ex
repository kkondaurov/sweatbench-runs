defmodule GroupStay.Groups.CreditApplication do
  @moduledoc """
  Credit from one lot currently funding a group's deposit. Preserves which
  lots funded a group so the amounts can be restored if the group is later
  cancelled while refundable.
  """

  use Ecto.Schema

  alias GroupStay.Groups.{CreditLot, Group}

  schema "credit_applications" do
    field :amount_cents, :integer
    field :operation_id, :string

    belongs_to :lot, CreditLot
    belongs_to :group, Group

    timestamps()
  end
end
