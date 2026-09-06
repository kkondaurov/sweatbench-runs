defmodule GroupStay.OperationRecord do
  use Ecto.Schema

  import Ecto.Changeset

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload_json, :string
    field :result_json, :string

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:operation_id, :operation_type, :payload_json, :result_json])
    |> validate_required([:operation_id, :payload_json, :result_json])
    |> unique_constraint(:operation_id)
  end
end
