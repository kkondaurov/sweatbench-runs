defmodule GroupStayWeb.PaymentJSON do
  @moduledoc """
  Renders the current disposition of cash from one recorded payment.
  """

  def show(%{statement: statement}) do
    %{data: statement}
  end
end
