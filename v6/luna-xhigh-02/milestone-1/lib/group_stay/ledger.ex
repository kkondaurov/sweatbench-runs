defmodule GroupStay.Ledger do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "ledger" do
    field :cash_refunded_cents, :integer
    field :cash_retained_cents, :integer
  end

  def changeset(ledger, attrs) do
    cast(ledger, attrs, [:cash_refunded_cents, :cash_retained_cents])
    |> validate_required([:cash_refunded_cents, :cash_retained_cents])
  end
end
