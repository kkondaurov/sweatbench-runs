defmodule GroupStay.Operations.OperationRecord do
  @moduledoc """
  The durable, idempotent record of one partner operation: what was submitted
  and the result that was returned. The primary key preserves the order in
  which records were first committed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string
    field :status, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:operation_id, :type, :payload, :result, :status])
    |> validate_required([:operation_id, :payload, :result, :status])
    |> unique_constraint(:operation_id)
  end
end
