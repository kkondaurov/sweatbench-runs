defmodule GroupStay.Credit.Lot do
  @moduledoc """
  A lot of hotel credit owned by a guest, issued by a cancellation.

  `remaining_cents` shrinks as the guest applies credit to later
  reservations. The lot is usable through the day before `expires_on` — it
  becomes a credit lot worth 110% of refunded cash, available through 365
  days after cancellation and expiring the following day.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    timestamps()
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_required([:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end
end
