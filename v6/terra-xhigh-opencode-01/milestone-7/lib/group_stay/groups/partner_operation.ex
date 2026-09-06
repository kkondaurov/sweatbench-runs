defmodule GroupStay.Groups.PartnerOperation do
  use Ecto.Schema

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload, :map
    field :result, :map
  end
end
