defmodule GroupStay.Partner.Params do
  @moduledoc """
  Readers for the raw JSON values in a partner operation.

  Every reader returns `:error` rather than raising, so a malformed operation is
  rejected instead of failing the batch.
  """

  @doc "A non-empty string field."
  def string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: :error, else: {:ok, value}

      _ ->
        :error
    end
  end

  @doc "An ISO 8601 calendar date field."
  def date(params, key) do
    with {:ok, value} <- string(params, key),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  @doc "An integer field. JSON floats are not integer cents and are refused."
  def integer(params, key) do
    case Map.get(params, key) do
      value when is_integer(value) -> {:ok, value}
      _ -> :error
    end
  end

  @doc "An optional integer field: `{:ok, nil}` when the key is absent."
  def optional_integer(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_integer(value) -> {:ok, value}
      _ -> :error
    end
  end
end
