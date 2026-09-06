defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance.Credit

  def show(conn, %{"guest_id" => guest_id} = params) do
    case GroupStayWeb.OnDate.fetch(params) do
      {:ok, on_date} ->
        lots = Credit.available_lots(guest_id, on_date)

        json(conn, %{
          data: %{
            guest_id: guest_id,
            available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
            lots: Enum.map(lots, &lot_json/1)
          }
        })

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_parameter"}})
    end
  end

  defp lot_json(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: Date.to_iso8601(lot.expires_on)
    }
  end
end
