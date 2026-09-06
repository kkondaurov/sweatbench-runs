defmodule GroupStay.Groups.HotelCreditLot do
  @moduledoc "A guest's available hotel-credit balance from one cancellation."

  use Ecto.Schema
  import Ecto.Changeset

  schema "hotel_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :issued_on, :date
    field :expires_on, :date
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:guest_id, :source_operation_id, :remaining_cents, :issued_on, :expires_on])
    |> validate_required([
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :issued_on,
      :expires_on
    ])
  end
end
