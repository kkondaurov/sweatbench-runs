defmodule GroupStay.Operations.Record do
  @moduledoc """
  The durable record of one partner operation.

  It is both the idempotency key for retries and Northstar's audit record of what
  the gateway submitted: `request_payload` is the complete submitted content in
  canonical JSON, and `result` is the result returned for it, applied or
  rejected. The primary key increases with each insert, so the rows read back in
  the order their operations were committed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :request_payload, :string
    field :result, :map

    timestamps(type: :utc_datetime_usec)
  end

  # `type` stays optional: an operation rejected for an unusable type is still
  # remembered, and its submitted content is retained in full either way.
  @fields [:operation_id, :type, :request_payload, :result]
  @required [:operation_id, :request_payload, :result]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> unique_constraint(:operation_id)
  end
end
