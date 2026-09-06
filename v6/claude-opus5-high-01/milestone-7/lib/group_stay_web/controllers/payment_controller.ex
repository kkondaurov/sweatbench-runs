defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Payments

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Payments.fetch_target(payment_operation_id) do
      {:ok, target} ->
        render(conn, :show, statement: Payments.statement(target))

      {:error, :not_found} ->
        error(conn, :not_found, "operation_not_found")

      # The identifier was used, but not by a payment there is anything to
      # reconcile.
      {:error, :not_a_payment} ->
        error(conn, :unprocessable_entity, "payment_not_reconcilable")
    end
  end

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code}})
  end
end
