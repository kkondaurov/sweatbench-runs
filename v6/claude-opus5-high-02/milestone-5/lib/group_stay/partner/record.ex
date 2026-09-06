defmodule GroupStay.Partner.Record do
  @moduledoc """
  The durable record of one partner operation GroupStay has committed a result for.

  The record serves two purposes at once. It is the idempotency key: `operation_id` is unique, and
  the record is written in the same transaction as the operation's domain changes, so a retry can
  be answered from the record instead of applying the operation again. It is also Northstar's
  audit record of the submission: `type` and `payload` retain what the gateway sent, and the
  autoincrementing primary key preserves the order in which records were first committed, because
  records are only ever inserted.

  `payload` is the complete submitted operation in a canonical JSON form, so that two submissions
  differing only in object key order compare equal. `type` repeats the type the gateway named, and
  is only `nil` when the submission did not name one as a string - the payload still holds what it
  sent. `result` is the JSON of the result the first attempt returned, which every retry receives
  verbatim.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "partner_operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string

    timestamps(type: :utc_datetime)
  end
end
