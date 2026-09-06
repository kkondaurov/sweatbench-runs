defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{
      "data" => %{
        "guest_id" => guest_id,
        "available_cents" => Finance.available_credit(guest_id, on_date(params)),
        "lots" =>
          Enum.map(Finance.credit_lots(guest_id, on_date(params)), fn {
                                                                        source_operation_id,
                                                                        remaining_cents,
                                                                        expires_on
                                                                      } ->
            %{
              "source_operation_id" => source_operation_id,
              "remaining_cents" => remaining_cents,
              "expires_on" => Date.to_iso8601(expires_on)
            }
          end)
      }
    })
  end

  defp on_date(params) do
    case params["on"] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          _ -> Date.utc_today()
        end

      _ ->
        Date.utc_today()
    end
  end
end
