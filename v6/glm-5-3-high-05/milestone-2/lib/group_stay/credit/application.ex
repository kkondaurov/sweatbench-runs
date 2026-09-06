defmodule GroupStay.Credit.Application do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer
    field :status, :string, default: "applied"

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :lot, GroupStay.Credit.Lot

    timestamps()
  end

  def changeset(application, attrs) do
    application
    |> Ecto.Changeset.cast(attrs, [:group_id, :lot_id, :amount_cents, :status])
    |> Ecto.Changeset.validate_required([:group_id, :lot_id, :amount_cents, :status])
    |> Ecto.Changeset.validate_number(:amount_cents, greater_than: 0)
    |> Ecto.Changeset.validate_inclusion(:status, ~w(applied restored consumed expired))
    |> Ecto.Changeset.assoc_constraint(:group)
    |> Ecto.Changeset.assoc_constraint(:lot)
  end
end
