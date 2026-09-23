defmodule GroupStay.OperationRecords.OperationRecord do
  @moduledoc """
  The durable record of a partner operation: what the gateway submitted and the result returned.

  `id` increases in the order records were committed. `payload` is the complete submitted
  operation as canonical JSON, and `result` is the returned result as JSON. Records are never
  updated or deleted.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string
    field :status, :string

    timestamps()
  end
end
