defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations
  alias GroupStayWeb.ReportingDate

  def show(conn, %{"guest_id" => guest_id} = params) do
    case ReportingDate.from_params(params) do
      {:ok, on} -> json(conn, %{data: credit_json(Reservations.guest_credit(guest_id, on))})
      {:error, :invalid_date} -> ReportingDate.render_error(conn)
    end
  end

  defp credit_json(credit) do
    %{
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
  end
end
