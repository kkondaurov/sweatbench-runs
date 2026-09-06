defmodule GroupStay.PartnerOperation do
  @moduledoc "The durable idempotency and audit record for a submitted partner operation."

  use Ecto.Schema
  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def reservation_changeset(operation, attrs) do
    operation
    |> cast(attrs, [:operation_id, :operation_type, :submission])
    |> validate_required([:operation_id, :submission])
    |> unique_constraint(:operation_id)
  end

  def result_changeset(operation, result) do
    operation
    |> change(result: result)
    |> validate_required([:result])
  end
end
