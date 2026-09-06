defmodule GroupStayWeb.Params do
  @moduledoc """
  Shared query parameter handling for read endpoints.
  """

  @doc """
  Resolves the optional `on=YYYY-MM-DD` reporting date, falling back to the
  current UTC date when the parameter is absent or not a usable date.
  """
  def reporting_date(params) do
    case date_param(params, "on") do
      {:ok, date} -> date
      :error -> Date.utc_today()
    end
  end

  @doc """
  Resolves the required `date=YYYY-MM-DD` query parameter. A missing or
  unusable date is an error, not a fallback.
  """
  @spec required_date(map()) :: {:ok, Date.t()} | :error
  def required_date(params), do: date_param(params, "date")

  defp date_param(params, key) do
    case params[key] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _error -> :error
        end

      _other ->
        :error
    end
  end
end
