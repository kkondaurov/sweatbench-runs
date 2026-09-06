defmodule GroupStay.Operation do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map

    timestamps()
  end
end
