defmodule GroupStayWeb.PaymentController do
  use GroupStayWeb, :controller

  alias GroupStay.Accounting
  alias GroupStay.DurableOperations.OperationRecord
  alias GroupStay.Repo

  import Ecto.Query

  @doc """
  Reconciles one durably recorded, applied cash payment: every amount is the
  current disposition of that payment's cash, and the six classifications
  sum exactly to the recorded amount. Reading never changes state.
  """
  def show(conn, %{"payment_operation_id" => payment_operation_id}) do
    record =
      Repo.one(from(r in OperationRecord, where: r.operation_id == ^payment_operation_id))

    cond do
      is_nil(record) ->
        not_found(conn, "operation_not_found")

      not applied_cash_payment?(record) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(422, Jason.encode!(%{error: %{code: "payment_not_reconcilable"}}))

      true ->
        recorded = Jason.decode!(record.result_json)["amount_cents"]
        statement = Accounting.payment_statement(payment_operation_id)

        data =
          %{"payment_operation_id" => payment_operation_id, "recorded_cents" => recorded}
          |> Map.merge(statement)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{data: data}))
    end
  end

  defp applied_cash_payment?(record) do
    record.type == "record_cash_payment" and
      match?(%{"status" => "applied", "amount_cents" => _}, Jason.decode!(record.result_json))
  rescue
    _ -> false
  end

  defp not_found(conn, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: %{code: code}}))
  end
end
