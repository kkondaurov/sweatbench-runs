defmodule GroupStay.Finance.ReportingSetting do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.PartnerOperation

  schema "finance_reporting_settings" do
    field :singleton, :integer, default: 1
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    belongs_to :partner_operation, PartnerOperation
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :singleton,
      :starts_on,
      :opening_credit_liability_cents,
      :partner_operation_id
    ])
    |> validate_required([
      :singleton,
      :starts_on,
      :opening_credit_liability_cents,
      :partner_operation_id
    ])
    |> validate_number(:opening_credit_liability_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:singleton)
    |> unique_constraint(:partner_operation_id)
  end
end
