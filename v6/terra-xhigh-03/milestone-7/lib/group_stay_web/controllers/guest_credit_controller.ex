defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"guest_id" => guest_id} = params) do
    case on_date(params) do
      {:ok, date} -> json(conn, %{data: Operations.guest_credit(guest_id, date)})
      :error -> invalid_date(conn)
    end
  end

  defp on_date(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp on_date(_params), do: {:ok, DateTime.utc_now() |> DateTime.to_date()}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
