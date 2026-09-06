defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  The durable reporting inception point. At most one row ever exists: it is
  created by the first applied `start_finance_reporting` operation and records
  the date reporting begins plus the opening position captured from the
  financial state immediately before that operation was processed.

  `opening_liability_cents` is the hotel-credit liability at inception, split
  between credit still available in lots (see
  `GroupStay.Finance.OpeningCreditLot`) and credit currently applied to active
  groups (`opening_applied_credit_cents`). Cash held per property at inception
  lives in `GroupStay.Finance.OpeningCash`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "finance_reportings" do
    field :singleton_lock, :string, default: "reporting"
    field :starts_on, :date
    field :start_operation_id, :string
    field :opening_liability_cents, :integer, default: 0
    field :opening_applied_credit_cents, :integer, default: 0

    has_many :opening_cash, GroupStay.Finance.OpeningCash, foreign_key: :reporting_id

    has_many :opening_credit_lots, GroupStay.Finance.OpeningCreditLot, foreign_key: :reporting_id

    timestamps(type: :utc_datetime)
  end

  def changeset(reporting, attrs) do
    cast(reporting, attrs, [
      :singleton_lock,
      :starts_on,
      :start_operation_id,
      :opening_liability_cents,
      :opening_applied_credit_cents
    ])
    |> validate_required([:singleton_lock, :starts_on])
    |> unique_constraint(:singleton_lock)
  end
end
