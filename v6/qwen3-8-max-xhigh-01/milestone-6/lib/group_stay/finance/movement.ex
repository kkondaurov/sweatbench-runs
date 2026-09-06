defmodule GroupStay.Finance.Movement do
  @moduledoc """
  One reported finance movement of an applied operation processed after
  reporting started.

  Cash movements carry the property where the cash is held or was settled and
  one of the cash kinds; credit movements carry the company-wide credit kinds
  and, where applicable, the affected credit lot. The internal kinds
  `"credit_applied"` and `"credit_restored"` are not report columns: they
  track how a lot's remaining balance moves between available and applied so
  a later report can compute the amount that expires with the lot.

  Amounts are signed net amounts within their named classification.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.CreditLot

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)
  @internal_kinds ~w(credit_applied credit_restored)

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_movements" do
    field :posting_date, :date
    field :kind, :string
    field :amount_cents, :integer
    field :property_id, :string

    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def cash_kinds, do: @cash_kinds
  def credit_kinds, do: @credit_kinds

  def create_changeset(%__MODULE__{} = movement, attrs) do
    movement
    |> cast(attrs, [:posting_date, :kind, :amount_cents, :property_id, :credit_lot_id])
    |> validate_required([:posting_date, :kind, :amount_cents])
    |> validate_inclusion(:kind, @cash_kinds ++ @credit_kinds ++ @internal_kinds)
  end
end
