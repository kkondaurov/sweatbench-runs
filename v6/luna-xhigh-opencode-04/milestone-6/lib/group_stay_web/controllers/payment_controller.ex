defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Operations.get_payment_reconciliation(payment_operation_id) do
      {:ok, payment} ->
        json(conn, %{data: payment})

      {:error, :not_found} ->
        not_found(conn, "operation_not_found")

      {:error, :not_reconcilable} ->
        not_found(conn, "payment_not_reconcilable", :unprocessable_entity)
    end
  end

  defp not_found(conn, code, status \\ :not_found) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code}})
  end
end
