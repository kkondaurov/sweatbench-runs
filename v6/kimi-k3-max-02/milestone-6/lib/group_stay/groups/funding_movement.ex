defmodule GroupStay.Groups.FundingMovement do
  @moduledoc """
  One funding movement recorded by an applied partner operation for the
  daily finance report.

  Cash-side movements are classified per property: `received`, `refunded`,
  `retained`, `converted_to_credit`, `reduced`, `charged_back`, and
  `transferred` (whose detail carries `destination_property_id` and the
  transferred `cash_cents` and `credit_cents`). Amounts are signed: a
  chargeback that reclassifies settled cash reports a negative amount under
  that settlement's original classification together with positive
  charged-back cash, so the settled property's held balance does not move.

  Credit-side movements are company-wide: `issued`, `expired`, `consumed`,
  `revoked`, and `absorbed` change the credit liability, while
  `applied_credit` and `restored_credit` only move credit between a lot's
  remaining balance and active groups — they carry `lot_id` so a report can
  reconstruct how much of a lot remained on its expiry date.

  `occurred_on` is the operation's own date; `posting_on` is the later of
  `occurred_on` and the reporting start date, so an operation submitted late
  still changes the correct open report. Rejected operations record nothing;
  a durable retry of the original operation reuses its stored rows instead
  of reporting the movement twice.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @cash_classifications ~w(received refunded retained converted_to_credit reduced charged_back transferred)
  @credit_classifications ~w(issued expired consumed revoked absorbed applied_credit restored_credit)

  @doc """
  The classifications that move per-property held cash, or company-wide
  credit liability, on the daily report. The remaining classifications
  (`transferred` cash detail excepted) only retrace lot balances.
  """
  def cash_classifications, do: @cash_classifications
  def credit_classifications, do: @credit_classifications

  schema "funding_movements" do
    field :operation_id, :string
    field :occurred_on, :date
    field :posting_on, :date
    field :side, :string
    field :classification, :string
    field :property_id, :string
    field :amount_cents, :integer
    field :detail, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [
      :operation_id,
      :occurred_on,
      :posting_on,
      :side,
      :classification,
      :property_id,
      :amount_cents,
      :detail
    ])
    |> validate_required([:occurred_on, :posting_on, :side, :classification, :amount_cents])
    |> validate_inclusion(:side, ["cash", "credit"])
    |> validate_classification()
  end

  defp validate_classification(changeset) do
    case {get_field(changeset, :side), get_field(changeset, :classification)} do
      {"cash", classification} when classification in @cash_classifications -> changeset
      {"credit", classification} when classification in @credit_classifications -> changeset
      _other -> add_error(changeset, :classification, "is not a known funding movement")
    end
  end
end
