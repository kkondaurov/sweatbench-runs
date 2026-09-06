defmodule GroupStayWeb.Params do
  @moduledoc """
  Shared query parameter handling for read endpoints.
  """

  @doc """
  Resolves the optional `on=YYYY-MM-DD` reporting date, falling back to the
  current UTC date when the parameter is absent or not a usable date.
  """
  def reporting_date(params) do
    case params["on"] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          _error -> Date.utc_today()
        end

      _other ->
        Date.utc_today()
    end
  end
end
