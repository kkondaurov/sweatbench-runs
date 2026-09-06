defmodule GroupStay.PartnerOperations.Operation do
  @moduledoc false

  use Ecto.Schema

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload, :map
    field :canonical_payload, :string
    field :result, :map

    timestamps(type: :utc_datetime)
  end
end
