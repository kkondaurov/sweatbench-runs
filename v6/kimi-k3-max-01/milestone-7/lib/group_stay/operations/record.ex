defmodule GroupStay.Operations.Record do
  @moduledoc """
  The durable idempotency and audit record for a partner operation.

  The first operation received for an `operation_id` is processed and
  remembered here together with its result; a later submission with an
  equivalent payload replays the stored result without touching domain
  state. `payload` retains the complete submitted content (JSON object key
  order is not significant) and the primary key order preserves the order in
  which records were first committed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:operation_id, :type, :payload, :result])
    |> validate_required([:operation_id, :payload, :result])
    |> unique_constraint(:operation_id)
  end
end
