defmodule GroupStay.Operation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:operation_id, :type, :submission, :result])
    |> validate_required([:operation_id, :submission, :result])
    |> unique_constraint(:operation_id)
  end
end
