defmodule GroupStayWeb.PaymentJSON do
  @moduledoc false

  def render("show.json", %{payment: payment}) do
    %{data: payment}
  end

  def render("not_found.json", _assigns) do
    %{error: %{code: "operation_not_found"}}
  end

  def render("not_reconcilable.json", _assigns) do
    %{error: %{code: "payment_not_reconcilable"}}
  end
end
