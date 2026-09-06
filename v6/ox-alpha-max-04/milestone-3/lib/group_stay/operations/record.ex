defmodule GroupStay.Operations.Record do
  @moduledoc """
  The durable record of one partner operation, keyed by its `operation_id`.

  `payload` is the canonical JSON of the submitted operation: object key
  order is normalized away, while array order and values remain significant,
  so an equivalent retry matches the original and any other payload is a
  conflict. `result` is the stored result returned verbatim to retries and to
  the operation read endpoint. `type` retains the submitted operation type for
  audit, and `sequence` preserves the order in which durable records were
  first committed.

  A handled rejection commits its record while leaving domain state
  unchanged; an unexpected exception rolls the whole transaction back and is
  never remembered.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string
    field :sequence, :integer

    timestamps(type: :utc_datetime)
  end
end
