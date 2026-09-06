defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"guest_id" => guest_id} = params) do
    case read_date(params["on"]) do
      {:ok, on} ->
        json(conn, %{data: Groups.guest_credit(guest_id, on)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp read_date(nil), do: {:ok, Date.utc_today()}

  defp read_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp read_date(_value), do: :error
end
