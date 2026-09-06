defmodule GroupStay.PartnerOperations.Operation do
  @moduledoc false
  use Ecto.Schema

  schema "partner_operations" do
    field :operation_id, :string
    # Missing or non-string types are retained in the complete payload.
    field :type, :string
    field :payload, :map
    field :result, :map
  end
end
