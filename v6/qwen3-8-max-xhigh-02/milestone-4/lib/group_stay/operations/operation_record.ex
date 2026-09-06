defmodule GroupStay.Operations.OperationRecord do
  @moduledoc """
  The durable record of a partner operation.

  Each remembered operation keeps its identifier, its type, the complete
  submitted content, and the exact result returned when it was first
  processed. The record is committed in the same transaction as any domain
  changes, so it doubles as the idempotency guard and as the audit record
  of what the gateway submitted. Rows appear in the order their records
  were first committed.
  """

  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map

    timestamps()
  end
end
