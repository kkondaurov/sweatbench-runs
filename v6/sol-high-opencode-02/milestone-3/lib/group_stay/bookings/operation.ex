defmodule GroupStay.Bookings.Operation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:operation_id, :operation_type, :submission, :result])
    |> validate_required([:operation_id, :submission, :result])
    |> unique_constraint(:operation_id)
  end
end
