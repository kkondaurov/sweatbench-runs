defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Payments

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Payments.fetch_statement(payment_operation_id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      {:error, :operation_not_found} ->
        error(conn, :not_found, "operation_not_found")

      {:error, :payment_not_reconcilable} ->
        error(conn, :unprocessable_entity, "payment_not_reconcilable")
    end
  end

  defp error(conn, status, code) do
    conn |> put_status(status) |> json(%{error: %{code: code}})
  end
end
