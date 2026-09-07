defmodule GroupStay.Operations.Record do
  @moduledoc """
  Immutable audit entry. IDs record commit order; submission retains all partner
  fields, including fields unknown to this version of the service.
  """
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map
  end
end
