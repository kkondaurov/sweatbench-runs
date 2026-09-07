defmodule GroupStay.PartnerOperations.OperationRecord do
  @moduledoc """
  The immutable audit and idempotency record for a partner operation.

  `submission` keeps the complete JSON object received from the gateway, while
  `result` is the exact API result produced on its first attempt. The integer
  primary key records the order in which operations first committed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:commit_order, :id, autogenerate: true}

  schema "partner_operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:operation_id, :operation_type, :submission, :result])
    |> validate_required([:operation_id, :submission, :result])
    |> unique_constraint(:operation_id)
  end
end
