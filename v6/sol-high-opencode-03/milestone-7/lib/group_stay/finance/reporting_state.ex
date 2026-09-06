defmodule GroupStay.Finance.ReportingState do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting_states" do
    field :start_operation_id, :string
    field :starts_on, :date
    field :latest_closed_on, :date
    field :opening_credit_liability_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :id,
      :start_operation_id,
      :starts_on,
      :latest_closed_on,
      :opening_credit_liability_cents
    ])
    |> validate_required([:id, :start_operation_id, :starts_on, :opening_credit_liability_cents])
    |> validate_number(:opening_credit_liability_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:start_operation_id)
  end
end
