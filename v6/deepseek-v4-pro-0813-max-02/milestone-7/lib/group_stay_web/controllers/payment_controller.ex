defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations
  alias GroupStay.RoomAccounting

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    case Operations.fetch_record(payment_operation_id) do
      {:ok, record} ->
        result = Jason.decode!(record.result)

        if record.type == "record_cash_payment" and result["status"] == "applied" do
          json(conn, %{data: statement(payment_operation_id, result)})
        else
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: %{code: "payment_not_reconcilable"}})
        end

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "operation_not_found"}})
    end
  end

  defp statement(payment_operation_id, result) do
    dispositions = RoomAccounting.payment_dispositions(payment_operation_id)

    base = %{
      payment_operation_id: payment_operation_id,
      original_group_id: result["group_id"],
      recorded_cents: result["amount_cents"],
      held_cents: dispositions.held_cents,
      refunded_cents: dispositions.refunded_cents,
      retained_cents: dispositions.retained_cents,
      converted_to_credit_cents: dispositions.converted_to_credit_cents,
      reduced_cents: dispositions.reduced_cents,
      charged_back_cents: dispositions.charged_back_cents
    }

    if RoomAccounting.payment_transferred?(payment_operation_id) do
      Map.put(base, :held_by_group, RoomAccounting.held_by_group(payment_operation_id))
    else
      base
    end
  end
end
