defmodule GroupStayWeb.ApiController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def submit_batch(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Operations.submit_batch(operations)})
  end

  def submit_batch(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end

  def show_group(conn, %{"group_id" => group_id}) do
    case Operations.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})

      group ->
        json(conn, %{data: group})
    end
  end

  def guest_credit(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, on} <- report_date(params) do
      json(conn, %{data: Operations.guest_credit(guest_id, on)})
    else
      :error -> invalid_date(conn)
    end
  end

  def ledger(conn, params) do
    with {:ok, on} <- report_date(params) do
      json(conn, %{data: Operations.ledger(on)})
    else
      :error -> invalid_date(conn)
    end
  end

  defp report_date(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp report_date(%{"on" => _value}), do: :error
  defp report_date(_params), do: {:ok, Date.utc_today()}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
