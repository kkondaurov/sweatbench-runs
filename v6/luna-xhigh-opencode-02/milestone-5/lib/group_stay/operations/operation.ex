defmodule GroupStay.Operations.Operation do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
