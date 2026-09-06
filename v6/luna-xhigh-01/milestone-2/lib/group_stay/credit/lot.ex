defmodule GroupStay.Credit.Lot do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "hotel_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
  end

  def changeset(lot, attrs) do
    Ecto.Changeset.cast(lot, attrs, [
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :expires_on
    ])
    |> Ecto.Changeset.validate_required([
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :expires_on
    ])
  end
end
