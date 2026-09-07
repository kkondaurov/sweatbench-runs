defmodule GroupStay.Finance.CreditLotOpening do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:credit_lot_id, :id, autogenerate: false}

  schema "finance_credit_lot_openings" do
    field :available_cents, :integer
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:credit_lot_id, :available_cents])
    |> validate_required([:credit_lot_id, :available_cents])
  end
end
