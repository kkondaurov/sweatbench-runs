defmodule GroupStay.Reservations.PartnerOperation do
  use Ecto.Schema

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_payload, :map
    field :canonical_payload, :string
    field :result, :map

    timestamps(type: :utc_datetime_usec)
  end
end
