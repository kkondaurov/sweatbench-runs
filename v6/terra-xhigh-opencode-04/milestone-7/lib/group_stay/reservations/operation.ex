defmodule GroupStay.Reservations.Operation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_payload, :map
    field :result, :map
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:operation_id, :operation_type, :submitted_payload, :result])
    |> validate_required([:operation_id, :submitted_payload, :result])
    |> unique_constraint(:operation_id)
  end
end
