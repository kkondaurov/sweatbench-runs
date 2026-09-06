defmodule GroupStayWeb.CreditController do
  use GroupStayWeb, :controller

  def show(conn, %{"guest_id" => guest_id} = params) do
    case as_of_date(params) do
      {:ok, as_of} ->
        json(conn, %{"data" => GroupStay.guest_credit(guest_id, as_of)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_date"}})
    end
  end

  defp as_of_date(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp as_of_date(%{"on" => _value}), do: :error

  defp as_of_date(_params), do: {:ok, Date.utc_today()}
end
