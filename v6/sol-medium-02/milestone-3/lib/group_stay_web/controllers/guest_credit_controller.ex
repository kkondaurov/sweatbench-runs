defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, on} <- report_date(params) do
      json(conn, %{data: Operations.guest_credit(guest_id, on)})
    else
      {:error, _reason} -> invalid_date(conn)
    end
  end

  defp report_date(%{"on" => value}) when is_binary(value), do: Date.from_iso8601(value)
  defp report_date(%{"on" => _value}), do: {:error, :invalid_format}
  defp report_date(_params), do: {:ok, Date.utc_today()}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
