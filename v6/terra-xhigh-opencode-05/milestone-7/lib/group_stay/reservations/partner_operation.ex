defmodule GroupStay.Reservations.PartnerOperation do
  use Ecto.Schema

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_payload, :string
    field :result, :string

    timestamps(updated_at: false)
  end
end
