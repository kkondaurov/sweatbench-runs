defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Operations.payment_statement(payment_operation_id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{"error" => %{"code" => "operation_not_found"}})

      :not_reconcilable ->
        conn
        |> put_status(422)
        |> json(%{"error" => %{"code" => "payment_not_reconcilable"}})

      statement ->
        json(conn, %{"data" => statement})
    end
  end
end
