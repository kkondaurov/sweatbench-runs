defmodule GroupStay.PartnerOperations.PartnerOperation do
  use Ecto.Schema

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_content, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end
end
