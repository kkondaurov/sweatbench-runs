defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credits
  alias GroupStayWeb.AsOfDate

  def show(conn, %{"guest_id" => guest_id} = params) do
    case AsOfDate.fetch(params) do
      {:ok, on} -> json(conn, %{data: data(Credits.guest_credit(guest_id, on))})
      :error -> AsOfDate.invalid(conn)
    end
  end

  defp data(credit) do
    %{
      guest_id: credit.guest_id,
      available_cents: credit.available_cents,
      lots: Enum.map(credit.lots, &lot/1)
    }
  end

  defp lot(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: lot.expires_on
    }
  end
end
