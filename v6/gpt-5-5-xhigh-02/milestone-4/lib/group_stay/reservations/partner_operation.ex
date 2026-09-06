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

  @create_fields ~w(operation_id operation_type payload)a

  def create_changeset(partner_operation, attrs) do
    partner_operation
    |> cast(attrs, @create_fields)
    |> validate_required([:payload])
    |> validate_operation_id_present()
    |> unique_constraint(:operation_id)
  end

  def result_changeset(partner_operation, attrs) do
    partner_operation
    |> cast(attrs, [:result])
    |> validate_required([:result])
  end

  defp validate_operation_id_present(changeset) do
    case get_field(changeset, :operation_id) do
      nil -> add_error(changeset, :operation_id, "can't be blank")
      _operation_id -> changeset
    end
  end
end
