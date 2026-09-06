defmodule GroupStayWeb.OnDate do
  @moduledoc """
  Resolves the `on=YYYY-MM-DD` query parameter shared by the credit reads.
  An unusable or missing value falls back to the current UTC date.
  """

  def from_params(params) do
    case params do
      %{"on" => on} when is_binary(on) ->
        case Date.from_iso8601(on) do
          {:ok, date} -> date
          {:error, _} -> today()
        end

      _ ->
        today()
    end
  end

  defp today, do: Date.utc_today()
end
