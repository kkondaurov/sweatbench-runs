defmodule GroupStay.Operations.Record do
  @moduledoc """
  Durable gateway audit entry. The integer primary key orders first commits, since
  SQLite permits only one writer at a time. Retries never insert another entry.

  Submission retains every JSON field, including unknown fields and invalid types.
  `type` is the submitted string type when present, for convenient audit queries.
  """
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map
  end
end
