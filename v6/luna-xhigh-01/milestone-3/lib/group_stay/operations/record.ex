defmodule GroupStay.Operations.Record do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload_json, :string
    field :result_json, :string
  end

  def changeset(record, attrs) do
    Ecto.Changeset.cast(record, attrs, [:operation_id, :type, :payload_json, :result_json])
    |> Ecto.Changeset.validate_required([:operation_id, :payload_json, :result_json])
  end
end
