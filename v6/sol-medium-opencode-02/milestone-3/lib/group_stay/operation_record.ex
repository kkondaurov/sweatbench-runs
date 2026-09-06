defmodule GroupStay.OperationRecord do
  use Ecto.Schema

  import Ecto.Changeset

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:operation_id, :operation_type, :submission, :result])
    |> validate_required([:operation_id, :submission, :result])
    |> unique_constraint(:operation_id)
  end
end
