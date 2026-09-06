defmodule GroupStay.Operations.Operation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:operation_id, :type, :payload, :result])
    |> validate_required([:operation_id, :payload])
    |> unique_constraint(:operation_id)
  end
end
