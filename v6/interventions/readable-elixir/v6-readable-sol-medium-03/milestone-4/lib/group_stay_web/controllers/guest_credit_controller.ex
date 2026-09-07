defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits
  alias GroupStayWeb.ReportingDate

  def show(conn, %{"guest_id" => guest_id} = params) do
    case ReportingDate.parse(params) do
      {:ok, on} -> json(conn, %{data: credit_json(Deposits.guest_credit(guest_id, on))})
      {:error, _reason} -> invalid_date(conn)
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

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
