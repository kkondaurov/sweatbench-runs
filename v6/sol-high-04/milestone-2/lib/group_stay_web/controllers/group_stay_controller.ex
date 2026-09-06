defmodule GroupStayWeb.GroupStayController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def submit_batch(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Operations.process_batch(operations)})
  end

  def submit_batch(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end

  def show_group(conn, %{"group_id" => group_id}) do
    case Operations.get_group(group_id) do
      {:ok, group} ->
        json(conn, %{data: Operations.group_view(group)})

      {:error, :group_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})
    end
  end

  def guest_credit(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, on} <- reporting_date(params) do
      json(conn, %{data: Operations.guest_credit_view(guest_id, on)})
    else
      :error -> invalid_date(conn)
    end
  end

  def ledger(conn, params) do
    with {:ok, on} <- reporting_date(params) do
      json(conn, %{data: Operations.ledger_view(on)})
    else
      :error -> invalid_date(conn)
    end
  end

  defp reporting_date(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp reporting_date(%{"on" => _on}), do: :error
  defp reporting_date(_params), do: {:ok, Date.utc_today()}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
