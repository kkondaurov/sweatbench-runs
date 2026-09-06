defmodule GroupStay.Finance.Posting do
  @moduledoc false

  # The reporting posting of one operation: the date all of its finance
  # effects use, and whether that date was moved forward by a period close.
  @enforce_keys [:date]
  defstruct [:date, late: false]
end
