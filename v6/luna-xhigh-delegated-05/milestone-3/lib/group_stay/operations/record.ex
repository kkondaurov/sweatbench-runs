defmodule GroupStay.Operations.Record do
  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload_json, :string
    field :result_json, :string

    timestamps(type: :utc_datetime_usec)
  end
end
