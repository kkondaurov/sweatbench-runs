defmodule GroupStay.Operations.Operation do
  @moduledoc """
  The durable audit and idempotency record for one partner operation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :commit_sequence, :integer
    field :payload_json, :string
    field :result_json, :string
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :operation_id,
      :operation_type,
      :commit_sequence,
      :payload_json,
      :result_json
    ])
    |> validate_required([:operation_id, :commit_sequence, :payload_json, :result_json])
    |> unique_constraint(:operation_id)
  end
end
