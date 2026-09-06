defmodule GroupStay.Ledger do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "ledger" do
    field :cash_refunded_cents, :integer
    field :cash_retained_cents, :integer
    field :cash_converted_to_credit_cents, :integer
    field :cash_reduced_cents, :integer
    field :cash_charged_back_cents, :integer
  end

  def changeset(ledger, attrs) do
    attrs = Map.put_new(attrs, :cash_converted_to_credit_cents, 0)
    attrs = Map.put_new(attrs, :cash_reduced_cents, 0)
    attrs = Map.put_new(attrs, :cash_charged_back_cents, 0)

    cast(ledger, attrs, [
      :cash_refunded_cents,
      :cash_retained_cents,
      :cash_converted_to_credit_cents,
      :cash_reduced_cents,
      :cash_charged_back_cents
    ])
    |> validate_required([
      :cash_refunded_cents,
      :cash_retained_cents,
      :cash_converted_to_credit_cents,
      :cash_reduced_cents,
      :cash_charged_back_cents
    ])
  end
end
