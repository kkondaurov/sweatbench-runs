defmodule GroupStay.Operations.Record do
  @moduledoc """
  The durable record of a partner operation, committed in the same transaction
  as the operation's domain changes. It is both the idempotency key that keeps
  gateway retries from applying an operation twice and Northstar's audit
  record of what was submitted.

  `payload` and `result` hold canonical JSON text: the complete submitted
  content and the exact returned result. Object key order is not significant,
  so payloads are stored with keys sorted recursively; array order and values
  remain significant.

  The auto-incremented primary key preserves the order in which records were
  first committed.
  """

  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string

    timestamps(type: :utc_datetime)
  end
end
