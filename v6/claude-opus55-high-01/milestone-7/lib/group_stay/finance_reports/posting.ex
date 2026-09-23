defmodule GroupStay.FinanceReports.Posting do
  @moduledoc """
  One finance effect on a report date.

  Kinds for held cash, recorded with the `property_id` holding or settling the cash:

    * `opening_held` - cash held when reporting started, dated `starts_on`;
    * `received`, `transferred_in`, `transferred_out`, `refunded`, `retained`,
      `converted_to_credit`, `reduced`, `charged_back` - signed movements.

  Kinds for the credit liability, recorded without a property:

    * `opening_liability` - the liability when reporting started, dated `starts_on`;
    * `issued`, `expired`, `consumed`, `revoked`, `absorbed` - signed movements.

  Kinds for the unapplied balance of the lot `lot_ref`, which expires on the lot's `expires_on`:

    * `opening_lot_balance` - the balance when reporting started;
    * `lot_balance` - a change dated before the lot's `expires_on`.

  `late_adjustment` marks a posting whose date a period close moved forward: the operation
  occurred in a closed period and posts on the first open day instead.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "finance_postings" do
    field :operation_id, :string
    field :posting_date, :date
    field :property_id, :string
    field :lot_ref, :integer
    field :kind, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false

    timestamps()
  end
end
