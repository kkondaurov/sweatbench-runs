defmodule GroupStay.Reservations.PartnerOperation do
  @moduledoc false

  use Ecto.Schema

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
