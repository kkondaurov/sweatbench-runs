defmodule GroupStay.Finance.ReportOpening do
  @moduledoc """
  One opening position captured when finance reporting starts.

  A `"cash"` row carries the held cash on `starts_on` for one property; the
  single `"credit"` row carries the company-wide credit liability on that
  date.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_report_openings" do
    field :scope, :string
    field :property_id, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
