defmodule GroupStay.Operations.OperationRecord do
  @moduledoc """
  The durable record of one handled partner operation.

  A record commits in the same database transaction as the domain changes it
  describes, so an operation is applied at most once: a retry with the same
  `operation_id` and an equivalent payload replays the stored result, and a
  different payload is rejected without replacing the record.

  Records are also Northstar's audit trail of what the gateway submitted.
  Each one retains the operation type and the complete submitted payload, and
  the auto-incrementing `id` preserves the order in which records were first
  committed.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string

    timestamps(type: :utc_datetime)
  end
end
