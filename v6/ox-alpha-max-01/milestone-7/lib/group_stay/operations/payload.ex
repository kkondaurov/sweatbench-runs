defmodule GroupStay.Operations.Payload do
  @moduledoc """
  Canonical comparison of submitted operation payloads.

  JSON object key order carries no meaning, so equivalence is judged on the
  recursive structure with every object key normalized to a string. Array
  order and all values remain significant.
  """

  @doc """
  A deterministic textual form of a decoded JSON value: object keys are
  normalized to strings and sorted; array order and values are preserved.
  Two submissions with the same `canonical_json` are equivalent.
  """
  def canonical_json(term) do
    term |> normalize() |> encode()
  end

  @doc """
  Whether two decoded JSON values are equivalent: equal once object keys are
  normalized to strings, keeping array order and values significant.
  """
  def equivalent?(left, right), do: normalize(left) == normalize(right)

  defp normalize(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {key_to_string(key), normalize(inner)} end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value), do: value

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: to_string(key)

  defp encode(value) when is_map(value) do
    inner =
      value
      |> Enum.sort()
      |> Enum.map_join(",", fn {key, inner_value} ->
        Jason.encode!(key) <> ":" <> encode(inner_value)
      end)

    "{" <> inner <> "}"
  end

  defp encode(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode/1) <> "]"
  end

  defp encode(value), do: Jason.encode!(value)
end
