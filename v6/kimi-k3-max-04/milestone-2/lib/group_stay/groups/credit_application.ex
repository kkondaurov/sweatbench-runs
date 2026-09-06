defmodule GroupStay.Groups.CreditApplication do
  @moduledoc """
  An amount of a credit lot applied to a group's deposit. The link is kept so
  the amount returns to its original lot on a refundable cancellation and is
  consumed on a non-refundable one.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :lot, GroupStay.Groups.CreditLot, type: :binary_id
    belongs_to :group, GroupStay.Groups.Group, type: :binary_id

    timestamps()
  end
end
