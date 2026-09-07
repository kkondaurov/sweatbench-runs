defmodule GroupStay.Deposits.OperationRecord do
  @moduledoc """
  The durable receipt for a partner operation.

  The database identifier is also the journal's commit order. SQLite permits only one writer at a
  time, and partner operations acquire that write lock before inserting a receipt, so identifiers
  follow the order in which operations are first committed.

  `submitted_content` retains the complete JSON object for audit purposes. `result` is the exact
  response returned to the partner and is replayed without consulting current domain state.
  """

  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_content, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end
end
