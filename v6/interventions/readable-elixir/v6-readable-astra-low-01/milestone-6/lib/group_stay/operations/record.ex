defmodule GroupStay.Operations.Record do
  @moduledoc """
  Immutable submission and result. The increasing database ID records first-commit
  order: SQLite serializes writers, and retries never insert another row.
  """
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map
  end
end
