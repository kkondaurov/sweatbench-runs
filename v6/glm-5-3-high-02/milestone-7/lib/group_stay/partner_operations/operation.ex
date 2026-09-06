defmodule GroupStay.PartnerOperations.Operation do
  @moduledoc """
  The durable record of a partner operation: its identifier, its
  submitted type and content, and the exact result returned when it was
  first processed.

  One row exists per distinct `operation_id` first received by this
  release. The auto-incremented primary key preserves the order in which
  records were first committed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string

    timestamps()
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:operation_id, :type, :payload, :result])
    |> validate_required([:operation_id, :payload, :result])
    |> unique_constraint(:operation_id)
  end
end
