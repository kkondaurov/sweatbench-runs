defmodule GroupStay.Operations.PartnerOperation do
  @moduledoc """
  The durable audit and idempotency record for a partner operation.

  SQLite's integer primary key records the order in which audit rows are first
  committed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_payload, :map
    field :payload_fingerprint, :binary
    field :result, :map

    timestamps()
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :operation_id,
      :operation_type,
      :submitted_payload,
      :payload_fingerprint,
      :result
    ])
    |> validate_required([:operation_id, :submitted_payload, :payload_fingerprint, :result])
    |> unique_constraint(:operation_id)
  end
end
