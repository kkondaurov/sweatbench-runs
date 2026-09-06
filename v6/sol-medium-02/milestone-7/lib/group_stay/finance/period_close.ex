defmodule GroupStay.Finance.PeriodClose do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.PartnerOperation

  schema "finance_period_closes" do
    field :period_end_on, :date
    belongs_to :partner_operation, PartnerOperation
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:period_end_on, :partner_operation_id])
    |> validate_required([:period_end_on, :partner_operation_id])
    |> unique_constraint(:period_end_on)
    |> unique_constraint(:partner_operation_id)
  end
end
