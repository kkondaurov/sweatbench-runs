defmodule GroupStay.Finance.ReportMovement do
  @moduledoc """
  One signed report movement recorded by an operation applied after finance
  reporting started.

  Cash classifications are attributed to a property; credit classifications
  are company-wide and carry a null `property_id`. Amounts are signed net
  amounts within their classification.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_report_movements" do
    field :posting_date, :date
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
