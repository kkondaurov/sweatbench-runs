defmodule GroupStay.PartnerOperation do
  @moduledoc """
  The durable audit and idempotency record for a partner operation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end

  def create_changeset(operation, attrs) do
    operation
    |> cast(attrs, [:operation_id, :operation_type, :payload, :result])
    |> validate_required([:operation_id, :payload, :result])
    |> unique_constraint(:operation_id)
  end
end
