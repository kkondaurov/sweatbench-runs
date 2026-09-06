defmodule GroupStay.Groups.CreditApplication do
  @moduledoc """
  An amount of a credit lot applied to a room of a group's deposit. The lot
  link is kept so the amount returns to its original lot on a refundable
  cancellation and is consumed on a non-refundable one; the room link settles
  it with the right room when selected rooms are cancelled.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :lot, GroupStay.Groups.CreditLot, type: :binary_id
    belongs_to :group, GroupStay.Groups.Group, type: :binary_id
    belongs_to :room, GroupStay.Groups.Room, type: :binary_id

    timestamps()
  end
end
