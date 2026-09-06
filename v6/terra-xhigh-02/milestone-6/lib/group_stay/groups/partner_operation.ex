defmodule GroupStay.Groups.PartnerOperation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission_json, :string
    field :result_json, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:operation_id, :operation_type, :submission_json, :result_json],
      empty_values: []
    )
    |> validate_required([:operation_id, :submission_json, :result_json])
    |> validate_length(:operation_id, min: 1)
    |> unique_constraint(:operation_id)
  end
end
