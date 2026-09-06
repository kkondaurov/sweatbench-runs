defmodule GroupStay.Operation do
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map
  end
end
