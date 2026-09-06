defmodule GroupStay.Operations.Operation do
  @moduledoc """
  The durable record of a partner operation submitted under this release.

  The first operation received for an `operation_id` is applied (or rejected)
  and its result is remembered here, together with the complete submitted
  content, so retries that lose a response can be answered with the exact
  original outcome without reapplying the operation.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(operation, attrs) do
    operation
    |> Ecto.Changeset.cast(attrs, [:operation_id, :type, :payload, :result])
    |> Ecto.Changeset.validate_required([:operation_id, :payload, :result])
    |> Ecto.Changeset.unique_constraint(:operation_id)
  end
end
