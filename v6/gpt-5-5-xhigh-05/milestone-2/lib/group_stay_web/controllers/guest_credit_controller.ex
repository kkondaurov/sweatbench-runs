defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.GroupReservations

  def show(conn, %{"guest_id" => guest_id} = params) do
    case on_date(params) do
      {:ok, on_date} ->
        json(conn, %{data: GroupReservations.guest_credit_payload(guest_id, on_date)})

      :invalid_on ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_on"}})
    end
  end

  defp on_date(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :invalid_on
    end
  end

  defp on_date(%{"on" => _value}), do: :invalid_on
  defp on_date(_params), do: {:ok, Date.utc_today()}
end
