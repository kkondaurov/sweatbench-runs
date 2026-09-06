defmodule GroupStay.GroupReservations.FinanceReportingStart do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.GroupReservations.FinanceCashOpeningPosition

  schema "finance_reporting_starts" do
    field :operation_id, :string
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer, default: 0
    field :singleton, :boolean, default: true

    has_many :cash_opening_positions, FinanceCashOpeningPosition

    timestamps(type: :utc_datetime)
  end

  def changeset(reporting_start, attrs) do
    reporting_start
    |> cast(attrs, [
      :operation_id,
      :starts_on,
      :opening_credit_liability_cents,
      :singleton
    ])
    |> validate_required([
      :operation_id,
      :starts_on,
      :opening_credit_liability_cents,
      :singleton
    ])
    |> validate_number(:opening_credit_liability_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:operation_id)
    |> unique_constraint(:singleton)
  end
end
