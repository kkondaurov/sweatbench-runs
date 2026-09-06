defmodule GroupStayWeb.PaymentController do
  @moduledoc """
  Reconciles one durably recorded, applied cash payment: the current
  disposition of its cash. Reading a statement never changes state.
  """

  use GroupStayWeb, :controller

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case GroupStay.Operations.fetch_payment_statement(payment_operation_id) do
      {:ok, statement} ->
        json(conn, %{"data" => statement})

      {:error, :operation_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "operation_not_found"}})

      {:error, :payment_not_reconcilable} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "payment_not_reconcilable"}})
    end
  end
end
