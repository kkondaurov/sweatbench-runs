defmodule GroupStay.Finance.ClosedReport do
  @moduledoc """
  The published `data` value of one daily finance report, frozen when a
  close committed its date. Reading a published date returns this stored
  value verbatim, so published figures never move again — not across
  later operations, later closes, or process restarts.
  """

  use Ecto.Schema

  schema "finance_closed_reports" do
    field :report_on, :date
    field :data, :string
    field :closed_by_operation_id, :string

    timestamps()
  end
end
