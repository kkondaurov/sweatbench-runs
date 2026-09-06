defmodule GroupStay.Finance.OpeningCredit do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_reporting_opening_credit" do
    field :credit_lot_id, :integer
    field :available_cents, :integer
  end

  def changeset(opening_credit, attrs) do
    Ecto.Changeset.cast(opening_credit, attrs, [:credit_lot_id, :available_cents])
    |> Ecto.Changeset.validate_required([:credit_lot_id, :available_cents])
  end
end
