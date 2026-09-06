defmodule GroupStay.Reservations.OperationRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload_json, :string
    field :result_json, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(operation_record, attrs) do
    operation_record
    |> cast(attrs, [:operation_id, :operation_type, :payload_json, :result_json])
    |> validate_required([:operation_id, :payload_json])
    |> unique_constraint(:operation_id)
  end

  def result_changeset(operation_record, attrs) do
    operation_record
    |> cast(attrs, [:result_json])
    |> validate_required([:result_json])
  end
end
