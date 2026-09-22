defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Payments

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Payments.fetch_statement(join_id(payment_operation_id)) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      {:error, :not_reconcilable} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "payment_not_reconcilable"}})
    end
  end

  defp join_id(payment_operation_id) when is_binary(payment_operation_id),
    do: payment_operation_id

  defp join_id(payment_operation_id) when is_list(payment_operation_id),
    do: Enum.join(payment_operation_id, "/")
end
