defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credits
  alias GroupStayWeb.ReportingDate

  def show(conn, %{"guest_id" => guest_id} = params) do
    case ReportingDate.parse(params) do
      {:ok, on} ->
        credit = Credits.available_credit(guest_id, on)

        json(conn, %{
          "data" => %{
            "guest_id" => guest_id,
            "available_cents" => credit.available_cents,
            "lots" => Enum.map(credit.lots, &render_lot/1)
          }
        })

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_date"}})
    end
  end

  defp render_lot(lot) do
    %{
      "source_operation_id" => lot.source_operation_id,
      "remaining_cents" => lot.remaining_cents,
      "expires_on" => Date.to_iso8601(lot.expires_on)
    }
  end
end
