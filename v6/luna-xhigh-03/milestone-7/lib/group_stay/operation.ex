defmodule GroupStay.Operation do
  @moduledoc "The durable audit and idempotency record for a partner operation."

  use Ecto.Schema

  @primary_key {:commit_order, :id, autogenerate: true}

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload_json, :string
    field :result_json, :string
  end
end
