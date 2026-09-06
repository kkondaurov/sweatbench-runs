defmodule GroupStay.Operations.Record do
  @moduledoc """
  The durable record of one partner operation.

  The record is Northstar's idempotency and audit entry for a submitted
  operation: it keys the operation by its identifier, retains the submitted
  payload and its type in canonical JSON form (object key order is not
  significant), and stores the complete result returned for the first attempt.

  The autoincrement integer primary key preserves the order in which records
  were first committed.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "operation_records" do
    field :operation_key, :string
    field :type, :string
    field :payload, :string
    field :status, :string
    field :result, :string

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> Ecto.Changeset.cast(attrs, [:operation_key, :type, :payload, :status, :result])
    |> Ecto.Changeset.validate_required([:operation_key, :payload, :status, :result])
    |> Ecto.Changeset.unique_constraint(:operation_key)
  end
end
