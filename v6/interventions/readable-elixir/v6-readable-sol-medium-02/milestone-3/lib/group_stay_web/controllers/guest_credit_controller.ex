defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, on} <- report_date(params) do
      credit = Reservations.guest_credit(guest_id, on)

      json(conn, %{
        data: %{
          guest_id: credit.guest_id,
          available_cents: credit.available_cents,
          lots:
            Enum.map(credit.lots, fn lot ->
              %{
                source_operation_id: lot.source_operation_id,
                remaining_cents: lot.remaining_cents,
                expires_on: lot.expires_on
              }
            end)
        }
      })
    else
      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp report_date(%{"on" => value}), do: Date.from_iso8601(value)
  defp report_date(_params), do: {:ok, Date.utc_today()}
end
