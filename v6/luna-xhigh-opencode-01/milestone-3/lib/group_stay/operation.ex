defmodule GroupStay.Operation do
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload, :string
    field :result, :string

    timestamps()
  end
end
