defmodule GroupStay.Groups.FinanceReporting do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting" do
    field :starts_on, :date
    field :latest_closed_on, :date
    field :opening_credit_liability_cents, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:starts_on, :latest_closed_on, :opening_credit_liability_cents])
    |> validate_required([:starts_on, :opening_credit_liability_cents])
  end
end
