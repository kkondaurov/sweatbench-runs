defmodule GroupStay.Operations.Record do
  @moduledoc """
  The durable record of a partner operation.

  A record is both the idempotency record that prevents the operation from
  being applied twice and the audit record of what the gateway submitted.
  `payload` holds the complete submitted content as JSON (object key order is
  not significant) and `result` holds the exact result returned for the
  operation, applied or rejected. The integer primary key preserves the order
  in which records were first committed.
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
