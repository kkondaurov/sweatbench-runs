defmodule GroupStay.Groups.PartnerOperation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:operation_id, :operation_type, :submission, :result])
    |> validate_required([:operation_id, :submission, :result])
    |> unique_constraint(:operation_id)
  end
end
