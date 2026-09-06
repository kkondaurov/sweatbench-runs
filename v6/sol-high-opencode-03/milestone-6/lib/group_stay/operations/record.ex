defmodule GroupStay.Operations.Record do
  use Ecto.Schema
  import Ecto.Changeset

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_content, :map
    field :result, :map

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:operation_id, :operation_type, :submitted_content, :result])
    |> validate_required([:operation_id, :submitted_content, :result])
    |> unique_constraint(:operation_id)
  end
end
