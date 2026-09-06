defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  The durable reporting inception point.

  The first applied `start_finance_reporting` operation inserts this
  singleton: `starts_on` is the first reportable date, and the financial
  state immediately before that operation was processed became the opening
  position. `opening_credit_liability_cents` is the company-wide credit
  liability of that moment (lot balances whose expiry is still reportable,
  plus credit applied to active groups); the per-property opening cash is
  snapshotted in `GroupStay.Finance.CashOpening`.

  Movements committed with an id of `movement_floor_id` or less predate the
  start operation and belong to the opening position, never to a report.
  """

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    field :movement_floor_id, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(reporting, attrs) do
    reporting
    |> Ecto.Changeset.cast(attrs, [
      :id,
      :starts_on,
      :opening_credit_liability_cents,
      :movement_floor_id
    ])
    |> Ecto.Changeset.validate_required([
      :id,
      :starts_on,
      :opening_credit_liability_cents,
      :movement_floor_id
    ])
  end
end
