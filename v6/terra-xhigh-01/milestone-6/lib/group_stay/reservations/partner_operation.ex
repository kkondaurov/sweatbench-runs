defmodule GroupStay.Reservations.PartnerOperation do
  @moduledoc """
  A durably remembered partner operation and the result originally returned for it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_payload, :map
    field :payload_fingerprint, :binary
    field :result, :map

    timestamps(type: :utc_datetime)
  end

  def create_changeset(operation, attrs) do
    operation
    |> cast(attrs, [:operation_id, :operation_type, :submitted_payload, :payload_fingerprint])
    |> validate_required([:operation_id, :submitted_payload, :payload_fingerprint])
    |> unique_constraint(:operation_id)
  end
end
