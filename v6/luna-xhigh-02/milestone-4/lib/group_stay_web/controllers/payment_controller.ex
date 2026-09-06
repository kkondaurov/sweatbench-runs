defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Operations.payment(payment_operation_id) do
      {:ok, payment} -> json(conn, %{data: payment})
      :not_found -> error(conn, :not_found, "operation_not_found")
      :not_reconcilable -> error(conn, :unprocessable_entity, "payment_not_reconcilable")
    end
  end

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code}})
  end
end
