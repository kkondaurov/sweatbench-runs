defmodule GroupStay.Groups.OperationRecord do
  @moduledoc """
  The durable idempotency and audit record for a partner operation.

  The first operation received for an `operation_id` records its complete
  submitted content (`request`, JSON-encoded; object key order is not
  significant), its submitted `type` when it has one, and the result it
  computed first (`result`, JSON-encoded), whether applied or rejected.
  Encoded maps ignore key order, so equivalent payloads compare equal.

  The integer primary key is the SQLite ROWID: insertion (and therefore
  commit) order of the records is preserved and stays readable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :status, :string
    field :request, :string
    field :result, :string

    timestamps()
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:operation_id, :type, :status, :request, :result])
    |> unique_constraint(:operation_id)
  end
end
