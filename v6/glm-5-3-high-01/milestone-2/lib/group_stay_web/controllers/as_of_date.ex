defmodule GroupStayWeb.AsOfDate do
  @moduledoc """
  Parses the optional `on` query parameter used by expiry-aware reads.
  """

  def parse(params) do
    case params do
      %{"on" => value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> :error
        end

      _other ->
        {:ok, Date.utc_today()}
    end
  end
end
