defmodule GroupStay.Operations.Record do
  @moduledoc """
  The durable record of one partner operation.

  Each record is the idempotency marker and the audit entry for a submitted
  operation: it keeps the operation's type, its complete canonical submission,
  and the exact result that was first returned for it, in the order records
  were first committed (`seq`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:seq, :id, autogenerate: true}
  schema "operations" do
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
