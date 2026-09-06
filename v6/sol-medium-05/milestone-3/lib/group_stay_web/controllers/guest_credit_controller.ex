defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  def show(conn, %{"guest_id" => guest_id} = params) do
    case reporting_date(params) do
      {:ok, on} -> json(conn, %{data: Deposits.guest_credit(guest_id, on)})
      :error -> invalid_date(conn)
    end
  end

  defp reporting_date(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp reporting_date(%{"on" => _value}), do: :error
  defp reporting_date(_params), do: {:ok, Date.utc_today()}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
