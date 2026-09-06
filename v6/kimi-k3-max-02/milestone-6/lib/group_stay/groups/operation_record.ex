defmodule GroupStay.Groups.OperationRecord do
  @moduledoc """
  The durable idempotency record for a partner operation.

  The first operation received for an `operation_id` is remembered here
  together with its complete submitted content and the exact result it
  produced, whether applied or rejected. A later submission with the same
  identifier and an equivalent payload is answered from this record without
  touching current domain state.

  The record is also Northstar's audit trail of what the gateway submitted;
  the integer primary key preserves the order in which records were first
  committed.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:operation_id, :type, :submission, :result])
    |> validate_required([:operation_id, :submission, :result])
    |> unique_constraint(:operation_id)
  end
end
