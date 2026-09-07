defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  def show(conn, %{"payment_operation_id" => operation_id}) do
    case Deposits.get_payment(operation_id) do
      {:ok, payment} ->
        json(conn, %{data: payment})

      {:error, :operation_not_found} ->
        error(conn, :not_found, "operation_not_found")

      {:error, :payment_not_reconcilable} ->
        error(conn, :unprocessable_entity, "payment_not_reconcilable")
    end
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: %{code: code}})
end
