defmodule GroupStay.Groups.ReportingState do
  @moduledoc """
  The durable reporting inception point. The single row records the date on
  which finance reporting starts; the financial state immediately before the
  first applied `start_finance_reporting` operation is the opening position
  on that date.

  `movements_after_id` is the commit-order watermark: funding movements
  recorded up to it belong to the opening position, later ones are report
  movements. `opening_credit_liability_cents` snapshots the company-wide
  credit liability on `starts_on`; the opening cash position lives in the
  `reporting_cash_openings` rows and per-lot remaining credit in the
  `reporting_lot_openings` rows (queried schemaless).
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "reporting_states" do
    field :starts_on, :date
    field :movements_after_id, :integer, default: 0
    field :opening_credit_liability_cents, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [:starts_on, :movements_after_id, :opening_credit_liability_cents])
    |> validate_required([:starts_on, :movements_after_id, :opening_credit_liability_cents])
  end
end
