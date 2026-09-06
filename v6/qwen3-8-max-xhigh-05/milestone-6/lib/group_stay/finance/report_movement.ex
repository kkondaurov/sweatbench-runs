defmodule GroupStay.Finance.ReportMovement do
  @moduledoc """
  One finance effect posted by an operation processed after reporting started.

  A cash movement carries its property and one of the cash report entries; a
  credit movement is company-wide and, when it affects one lot's balance,
  carries that lot. `amount_cents` is the signed net amount within the named
  entry.

  The `"opening"`, `"applied"`, and `"restored"` entries are balance rows
  used to replay a lot's balance at its expiry; they never appear as report
  movements.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_report_movements" do
    field :on_date, :date
    field :scope, :string
    field :property_id, :string
    field :entry, :string
    field :amount_cents, :integer

    belongs_to :lot, GroupStay.Finance.CreditLot

    timestamps(type: :utc_datetime)
  end
end
