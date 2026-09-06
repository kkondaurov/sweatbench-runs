defmodule GroupStay.Operations.OperationRecord do
  @moduledoc """
  The durable idempotency and audit record for a partner operation.

  `submission` stores a canonical serialization of the complete submitted
  content (object key order is not significant). `result` stores the exact
  result returned when the operation was first processed, applied or rejected.
  """

  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :submission, :string
    field :result, :string

    timestamps(type: :utc_datetime)
  end
end
