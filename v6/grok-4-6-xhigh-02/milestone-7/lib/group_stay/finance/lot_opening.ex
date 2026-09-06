defmodule GroupStay.Finance.LotOpening do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_lot_openings" do
    field :source_operation_id, :string
    field :expires_on, :date
    field :remaining_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:source_operation_id, :expires_on, :remaining_cents])
    |> validate_required([:source_operation_id, :expires_on, :remaining_cents])
    |> unique_constraint(:source_operation_id)
  end
end
