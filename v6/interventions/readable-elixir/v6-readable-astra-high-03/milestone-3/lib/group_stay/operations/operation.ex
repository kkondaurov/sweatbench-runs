defmodule GroupStay.Operations.Operation do
  @moduledoc """
  Immutable audit record of a partner submission and its original JSON result.

  SQLite serializes writers, so the generated `id` orders first commits. Retries
  and conflicts never insert or update a record. `payload` retains every submitted
  field, including unknown fields and malformed types; `type` names the domain
  operation name when the submission supplies a string.
  """
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map
  end
end
