defmodule GroupStay.Operations.Record do
  @moduledoc """
  The durable record for a partner operation.

  A record commits in the same transaction as the operation's domain changes,
  so a retried operation identifier returns the original result without
  reading or changing current domain state. Handled rejections leave domain
  state unchanged but still commit their record.

  Records are also the audit record of what the gateway submitted: each one
  retains the operation type and the complete submitted payload, and the
  auto-incrementing primary key preserves the order in which records were
  first committed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = record, attrs) do
    record
    |> cast(attrs, [:operation_id, :type, :payload, :result])
    |> validate_required([:operation_id, :payload, :result])
    |> unique_constraint(:operation_id)
  end
end
