defmodule GroupStay.Reservations.PartnerOperation do
  @moduledoc """
  The durable receipt for one partner operation identifier.

  `submitted_payload` is the complete JSON value received from the gateway.
  The generated `commit_order` records the serialized order in which receipts
  first became durable; retries never update or replace a receipt.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:commit_order, :id, autogenerate: true}
  @derive {Inspect, except: [:submitted_payload]}
  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_payload, :map
    field :result, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def creation_changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [:operation_id, :operation_type, :submitted_payload, :result])
    |> validate_required([:operation_id, :submitted_payload, :result])
    |> unique_constraint(:operation_id)
  end
end
