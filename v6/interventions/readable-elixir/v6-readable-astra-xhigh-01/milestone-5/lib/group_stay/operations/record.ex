defmodule GroupStay.Operations.Record do
  @moduledoc """
  An immutable submission and its original partner-facing JSON result.

  SQLite assigns the increasing `id` while the operation holds the database's
  write reservation. It therefore orders first commits, independently of the
  partner's operation date or the wall clock. Retries never insert or update it.

  `payload` retains every submitted field, including unknown fields and malformed
  values. `operation_type` is the submitted type when it is a string; missing or
  malformed types remain represented in the complete payload.
  """

  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload, :map
    field :result, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
