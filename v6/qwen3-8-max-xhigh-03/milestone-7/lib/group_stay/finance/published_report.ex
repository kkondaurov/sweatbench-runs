defmodule GroupStay.Finance.PublishedReport do
  @moduledoc """
  The published, byte-for-byte frozen report for one closed day. When a close
  is processed, every day it newly closes is built exactly once and stored
  here; later reads of a closed day return the stored `data` verbatim, so a
  published day never moves regardless of later operations, later closes, or
  process restarts.
  """

  use Ecto.Schema

  @primary_key {:report_date, :date, autogenerate: false}

  schema "finance_published_reports" do
    field :data, :string

    timestamps(type: :utc_datetime)
  end
end
