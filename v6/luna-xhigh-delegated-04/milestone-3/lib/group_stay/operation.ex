defmodule GroupStay.Operation do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload_json, :string
    field :result_json, :string
  end
end
