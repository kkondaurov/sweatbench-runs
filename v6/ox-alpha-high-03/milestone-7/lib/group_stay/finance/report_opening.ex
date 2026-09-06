defmodule GroupStay.Finance.ReportOpening do
  @moduledoc """
  One line of the financial position captured when reporting started.

  Kind `cash_held` rows carry the held cash of one property; the single
  `credit_liability` row (null property) carries the company-wide hotel-credit
  liability as of the capture date.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_report_openings" do
    field :kind, :string
    field :property_id, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
