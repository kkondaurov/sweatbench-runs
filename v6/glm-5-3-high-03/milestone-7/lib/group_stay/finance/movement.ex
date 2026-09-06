defmodule GroupStay.Finance.Movement do
  @moduledoc """
  One reported movement of held cash or hotel-credit liability, recorded in
  the same transaction as the operation that caused it.

  Cash movements carry the property the cash was held at or settled through;
  credit movements, which describe the company-wide liability, carry no
  property. Amounts are signed net amounts within their classification.

  A movement whose posting date a finance period close moved forward — because
  its operation committed after that close with an `occurred_on` inside the
  closed period — is `late`: the daily report shows it in its
  `late_adjustments` block instead of its ordinary movement columns. The flag
  is fixed when the movement commits and never changes again.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_movements" do
    field :posting_date, :date
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
    field :late, :boolean, default: false

    timestamps(type: :utc_datetime)
  end
end
