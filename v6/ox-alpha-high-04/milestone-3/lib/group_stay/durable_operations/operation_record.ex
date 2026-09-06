defmodule GroupStay.DurableOperations.OperationRecord do
  @moduledoc """
  The durable record of an operation first received by this release.

  It doubles as Northstar's idempotency guard and audit trail: `payload_json`
  retains the complete submitted content (object key order is not
  significant) and `result_json` retains the exact result returned the first
  time. `type` keeps the operation's type for auditing.
  """

  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload_json, :string
    field :result_json, :string

    timestamps(type: :utc_datetime_usec)
  end
end
