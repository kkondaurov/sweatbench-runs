defmodule GroupStay.Reservations.PartnerOperation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end

  def changeset(partner_operation, attrs) do
    partner_operation
    |> cast(attrs, [:operation_id, :operation_type, :payload, :result])
    |> validate_required([:operation_id, :payload, :result])
    |> unique_constraint(:operation_id)
  end
end
