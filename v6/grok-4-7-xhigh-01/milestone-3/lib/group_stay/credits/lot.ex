defmodule GroupStay.Credits.Lot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :original_cents, :integer
    field :expires_on, :date
    field :issued_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :original_cents,
      :expires_on,
      :issued_on
    ])
    |> validate_required([
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :original_cents,
      :expires_on,
      :issued_on
    ])
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
    |> validate_number(:original_cents, greater_than: 0)
  end
end
