defmodule GroupStay.Finance.PeriodClose do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  schema "finance_reporting_period_closes" do
    field :period_end_on, :date

    timestamps()
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:period_end_on])
    |> validate_required([:period_end_on])
    |> unique_constraint(:period_end_on)
  end
end
