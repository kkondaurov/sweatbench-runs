defmodule GroupStay.Operation do
  @moduledoc false
  use Ecto.Schema

  # SQLite serializes writers; this increasing id records first commit order.
  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map
  end
end
