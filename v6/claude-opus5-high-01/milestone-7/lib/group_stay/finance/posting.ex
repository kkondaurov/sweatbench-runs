defmodule GroupStay.Finance.Posting do
  @moduledoc """
  The reporting date one operation's finance effects post to.

  `date` is the later of the operation's own date, the date reporting started,
  and the first day of the open period. `late?` says whether that last term is
  what chose it: a movement a close pushed out of the period it belonged to is
  reported as a late adjustment rather than as ordinary movement of the day it
  landed on.
  """

  defstruct [:date, late?: false]
end
