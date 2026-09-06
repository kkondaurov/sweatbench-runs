defmodule GroupStay.Operations.Operation do
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload_json, :string
    field :result_json, :string

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
