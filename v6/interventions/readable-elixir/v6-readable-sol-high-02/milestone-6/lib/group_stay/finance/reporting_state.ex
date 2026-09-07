defmodule GroupStay.Finance.ReportingState do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}

  schema "finance_reporting_states" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [:id, :starts_on, :opening_credit_liability_cents])
    |> validate_required([:id, :starts_on, :opening_credit_liability_cents])
  end
end
