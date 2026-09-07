defmodule GroupStay.Operations.Record do
  @moduledoc """
  An immutable submission and its original JSON result.

  The generated integer ID orders first commits: SQLite permits only one writer,
  and a record is inserted in the same transaction as its domain changes. Retries
  and conflicts never insert or update a record. `type` records the submitted
  string type; malformed types remain intact in `payload`.
  """
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map
  end
end
