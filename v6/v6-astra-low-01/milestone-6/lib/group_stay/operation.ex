defmodule GroupStay.Operation do
  use Ecto.Schema

  # IDs are allocated under the same SQLite write lock as the domain transaction.
  # Records are immutable: retries and conflicts never insert or update them.
  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map
  end
end
