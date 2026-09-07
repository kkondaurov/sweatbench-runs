defmodule GroupStay.FinanceReporting.Posting do
  @moduledoc """
  The reporting date selected when a partner operation commits.

  `late_adjustment?` distinguishes effects moved out of a closed period from
  ordinary effects whose business date was already in the open period.
  """

  defstruct [:date, late_adjustment?: false]
end
