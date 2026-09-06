defmodule GroupStay.Operations.Record do
  @moduledoc """
  Durable idempotency and audit record for a partner operation.

  The first operation received for an `operation_id` stores its submitted
  type and content plus the exact result returned, applied or rejected, in
  the same transaction as its domain effects. Rows are created in commit
  order.
  """

  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string

    timestamps()
  end
end
