defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  action_fallback GroupStayWeb.FallbackController

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Deposits.payment_statement(payment_operation_id) do
      {:ok, statement} -> render(conn, :show, statement: statement)
      {:error, reason} -> {:error, reason}
    end
  end
end
