defmodule GroupStay.FinanceReporting.Setting do
  @moduledoc "The reporting inception, opening credit position, and latest closed cutoff."

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_reporting_settings" do
    field :starts_on, :date
    field :latest_period_end_on, :date
    field :opening_credit_liability_cents, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:id, :starts_on, :latest_period_end_on, :opening_credit_liability_cents])
    |> validate_required([:id, :starts_on, :opening_credit_liability_cents])
  end
end
