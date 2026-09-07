defmodule GroupStay.Finance.Reporting.Entry do
  @moduledoc """
  An immutable set of signed movements committed with a partner operation.

  A property identifies cash movements; nil identifies company-wide credit.
  Expiry entries schedule changes to unused credit on the day after expiry.
  Later applications and restorations adjust that schedule with signed entries.
  Reads only sum entries and never expire or otherwise mutate domain records.

  The posting date and late-adjustment classification are fixed on insertion.
  A later close never moves an entry or changes its classification.
  """

  use Ecto.Schema

  schema "finance_reporting_entries" do
    field :operation_id, :string
    field :posted_on, :date
    field :property_id, :string
    field :movements, :map
    field :late_adjustment, :boolean, default: false
  end
end
