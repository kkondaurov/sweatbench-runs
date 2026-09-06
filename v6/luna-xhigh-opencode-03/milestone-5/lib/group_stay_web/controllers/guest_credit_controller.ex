defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"guest_id" => guest_id} = params) do
    case as_of(params) do
      {:ok, date} -> json(conn, %{data: Groups.guest_credit(guest_id, date)})
      :error -> invalid_date(conn)
    end
  end

  defp as_of(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp as_of(_params), do: {:ok, Date.utc_today()}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
