defmodule GroupStay.Finance.Entry do
  @moduledoc """
  An immutable reporting amount committed with its originating operation.

  Opening entries are balances, not movements. Other entries are signed net
  movements. Expiry entries schedule changes to unused liability on the day
  after a lot expires; redemption offsets that scheduled expiry. Keeping these
  contributions separately allows late submissions to amend open reports
  without rewriting history or making report reads mutate state.

  Amounts are stored per funding portion or credit lot. Reports sum in Elixir
  so company and property totals can exceed SQLite's signed integer range.
  """
  use Ecto.Schema

  schema "finance_entries" do
    field :operation_id, :string
    field :account, Ecto.Enum, values: [:cash, :credit]
    field :property_id, :string
    field :credit_lot_id, :id
    field :posted_on, :date

    field :kind, Ecto.Enum,
      values: [
        :opening,
        :received,
        :transferred_in,
        :transferred_out,
        :refunded,
        :retained,
        :converted_to_credit,
        :reduced,
        :charged_back,
        :issued,
        :expired,
        :consumed,
        :revoked,
        :absorbed
      ]

    field :amount_cents, :integer
  end
end
