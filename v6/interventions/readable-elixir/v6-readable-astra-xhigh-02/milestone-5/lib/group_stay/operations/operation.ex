defmodule GroupStay.Operations.Operation do
  @moduledoc """
  The immutable submission and JSON result of a partner operation.

  SQLite serializes writers, so the generated `id` orders first commits, including
  handled rejections. Retries and conflicts never insert or update a record.
  `payload` preserves every submitted field, including unknown fields and invalid
  types; `type` is also retained separately when it is a string.
  """

  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map
  end
end
