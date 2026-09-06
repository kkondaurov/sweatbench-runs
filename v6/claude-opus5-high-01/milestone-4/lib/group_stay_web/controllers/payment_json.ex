defmodule GroupStayWeb.PaymentJSON do
  @moduledoc """
  Renders where the cash of one recorded payment currently stands.

  The six dispositions add up to the amount the payment recorded.
  """

  def show(%{statement: statement}), do: %{data: statement}
end
