defmodule GroupStay.Reservations.PartnerOperation do
  use Ecto.Schema

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_json, :string
    field :result_json, :string

    timestamps(type: :utc_datetime)
  end
end
