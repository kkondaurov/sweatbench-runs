defmodule GroupStay.Deposits.Operation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string
    field :involved_in_transfer, :boolean, default: false

    timestamps()
  end

  @doc """
  Changeset for claiming an `operation_id` inside the operation's transaction.

  The insert doubles as the concurrency gate: the unique index on
  `operation_id` means exactly one transaction can ever claim an identifier.
  """
  def claim_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:operation_id, :type, :payload, :result])
    |> validate_required([:operation_id, :payload, :result])
    |> unique_constraint(:operation_id)
  end

  @doc "Changeset for recording the final result on a claimed operation."
  def result_changeset(%__MODULE__{} = operation, attrs) do
    operation
    |> cast(attrs, [:result])
    |> validate_required([:result])
  end
end
