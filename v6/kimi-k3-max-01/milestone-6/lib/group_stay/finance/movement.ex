defmodule GroupStay.Finance.Movement do
  @moduledoc """
  A posting-dated finance movement recorded by an applied partner operation
  after reporting started.

  Cash movements carry the property whose held cash moved; credit movements
  are company-wide (`property_id` is null). Amounts are signed within their
  classification: a reversal, such as a chargeback of settled cash, records a
  negative amount in the settled classification and a positive amount in
  `charged_back`. Movements are never updated or deleted; the daily report
  sums them by posting date.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @scopes ~w(cash credit)

  schema "finance_movements" do
    field :scope, :string
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :posting_on, :date

    timestamps(type: :utc_datetime)
  end

  def scopes, do: @scopes

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:scope, :property_id, :classification, :amount_cents, :posting_on])
    |> validate_required([:scope, :classification, :amount_cents, :posting_on])
    |> validate_inclusion(:scope, @scopes)
  end
end
