defmodule GroupStay.Finance.CashMovement do
  @moduledoc """
  One classified change to the cash a property holds, on the date it posts to.

  `amount_cents` is signed within its own classification: a refund posts a
  positive `refunded`, and a chargeback that reverses that refund posts a
  negative `refunded` alongside a positive `charged_back`.

  `late` marks a movement a period close pushed out of the period it belonged to.
  It posts to the first open day like any other movement, but a report reports it
  separately as a late adjustment.

  `opening` is not a movement. It carries the held cash a property brought into
  the reporting window and is dated the day before reporting starts, so it is
  always part of a report's opening balance and never part of its movements.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # The report column each classification posts to, in report order.
  @columns [
    {"received", :received_cents},
    {"transferred_in", :transferred_in_cents},
    {"transferred_out", :transferred_out_cents},
    {"refunded", :refunded_cents},
    {"retained", :retained_cents},
    {"converted_to_credit", :converted_to_credit_cents},
    {"reduced", :reduced_cents},
    {"charged_back", :charged_back_cents}
  ]

  # How each classification moves the cash a property holds.
  @signs %{
    "opening" => 1,
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted_to_credit" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }

  schema "finance_cash_movements" do
    field :posting_date, :date
    field :late, :boolean, default: false
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:posting_date, :late, :property_id, :classification, :amount_cents]

  @doc "The classifications a report names, paired with their report columns."
  def columns, do: @columns

  @doc "The effect one classified cent has on the cash a property holds."
  def sign(classification), do: Map.fetch!(@signs, classification)

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:classification, Map.keys(@signs))
  end
end
