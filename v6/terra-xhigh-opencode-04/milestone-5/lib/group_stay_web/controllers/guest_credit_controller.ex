defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, on} <- as_of_date(params),
         {:ok, credit} <- Reservations.guest_credit(guest_id, on) do
      json(conn, %{data: credit})
    else
      {:error, :invalid_date} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp as_of_date(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp as_of_date(%{"on" => _on}), do: {:error, :invalid_date}
  defp as_of_date(_params), do: {:ok, Date.utc_today()}
end
