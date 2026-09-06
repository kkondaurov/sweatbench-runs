defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Accounting
  alias GroupStay.Operations

  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Operations.get(payment_operation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})

      record ->
        payment = Accounting.get_cash_payment(payment_operation_id)

        if Accounting.applied_cash_payment?(record) and payment do
          json(conn, %{data: Accounting.payment_statement(payment)})
        else
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: %{code: "payment_not_reconcilable"}})
        end
    end
  end
end
