defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  def show(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, on} <- reporting_date(params) do
      json(conn, %{data: Deposits.guest_credit(guest_id, on)})
    else
      _error ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp reporting_date(%{"on" => value}) when is_binary(value), do: Date.from_iso8601(value)
  defp reporting_date(%{"on" => _value}), do: :error
  defp reporting_date(_params), do: {:ok, Date.utc_today()}
end
