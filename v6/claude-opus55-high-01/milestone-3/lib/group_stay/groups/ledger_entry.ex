defmodule GroupStay.Groups.LedgerEntry do
  @moduledoc """
  An accounting fact recorded against a group.

  Kinds:

    * `cash_payment` - cash applied to the group's deposit;
    * `cash_refund` - paid cash refunded on cancellation;
    * `cash_retained` - paid cash kept on cancellation;
    * `cash_converted_to_credit` - paid cash converted to hotel credit on cancellation.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "ledger_entries" do
    field :group_ref, :integer
    field :operation_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :occurred_on, :date

    timestamps()
  end
end
