defmodule GroupStay.Operations.OperationRecord do
  @moduledoc """
  The durable, audit-grade record of one received operation: its type, its
  complete submitted content in canonical form, and the exact original result.
  Records are insert-only; their insertion order is the commit order.
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

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:operation_id, :type, :payload, :result])
    |> validate_required([:operation_id, :payload, :result])
    |> unique_constraint(:operation_id)
  end
end
