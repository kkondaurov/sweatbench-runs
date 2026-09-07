defmodule GroupStay.Reservations.OperationRecord do
  @moduledoc """
  The immutable submission and JSON outcome of a partner's first attempt.

  Records are inserted with domain changes under SQLite's immediate write lock.
  Their generated integer IDs therefore preserve first-commit order, independent
  of partner dates or identifiers. Retries and conflicts never insert or update
  a record. Earlier releases' accounting references are not backfilled.

  The complete submission is retained, including unknown fields and invalid
  values. Comparing decoded JSON with strict equality ignores object key order
  while preserving array order and types (integer cents differ from floats).
  The type column records the submitted string type for audit purposes; missing
  or malformed types remain available verbatim in the submission.
  """
  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def new(operation, result) do
    %__MODULE__{
      operation_id: operation["operation_id"],
      type: if(is_binary(operation["type"]), do: operation["type"]),
      submission: operation,
      result: result
    }
  end
end
