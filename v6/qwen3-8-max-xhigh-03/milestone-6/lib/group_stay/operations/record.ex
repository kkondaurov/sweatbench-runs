defmodule GroupStay.Operations.Record do
  @moduledoc """
  The durable record for one partner operation: the idempotency entry that
  guarantees an `operation_id` is applied at most once, and the audit record
  of what the gateway submitted.

  `payload` is the canonical JSON encoding of the submitted operation (object
  key order is not significant); `result` is the JSON encoding of the exact
  result returned when the identifier was first handled. Records are only
  ever inserted, so their auto-incrementing ids preserve the order in which
  durable records were first committed.
  """

  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string

    timestamps(type: :utc_datetime)
  end
end
