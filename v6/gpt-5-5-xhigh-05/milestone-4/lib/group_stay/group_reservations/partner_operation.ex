defmodule GroupStay.GroupReservations.PartnerOperation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload_json, :string
    field :result_json, :string

    timestamps(type: :utc_datetime)
  end

  def create_changeset(partner_operation, attrs) do
    partner_operation
    |> cast(attrs, [:operation_id, :operation_type, :payload_json])
    |> validate_required([:operation_id, :payload_json])
    |> unique_constraint(:operation_id)
  end

  def result_changeset(partner_operation, attrs) do
    partner_operation
    |> cast(attrs, [:result_json])
    |> validate_required([:result_json])
  end
end
