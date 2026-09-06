defmodule GroupStay.Operations.CanonicalJson do
  @moduledoc """
  Encodes JSON-compatible terms into a canonical JSON string.

  Object members are serialized in sorted key order, so the encoding is
  independent of the key order a gateway used, while list order and every
  value remain significant. Two decoded JSON payloads are equivalent exactly
  when their canonical encodings are equal.
  """

  @doc """
  Returns the canonical JSON string for a decoded JSON term.
  """
  def encode!(term), do: IO.iodata_to_binary(do_encode(term))

  defp do_encode(nil), do: "null"
  defp do_encode(true), do: "true"
  defp do_encode(false), do: "false"
  defp do_encode(value) when is_integer(value), do: Integer.to_string(value)
  defp do_encode(value) when is_float(value), do: Jason.Encode.float(value)
  defp do_encode(value) when is_binary(value), do: Jason.encode!(value)

  defp do_encode(values) when is_list(values) do
    [?[, values |> Enum.map(&do_encode/1) |> Enum.intersperse(?,), ?]]
  end

  defp do_encode(value) when is_map(value) do
    members =
      value
      |> Enum.sort_by(fn {key, _value} -> member_key(key) end)
      |> Enum.map(fn {key, member} -> [Jason.encode!(member_key(key)), ?:, do_encode(member)] end)
      |> Enum.intersperse(?,)

    [?{, members, ?}]
  end

  defp do_encode(value) do
    raise ArgumentError, "cannot encode #{inspect(value)} as canonical JSON"
  end

  defp member_key(key) when is_binary(key), do: key
  defp member_key(key) when is_atom(key), do: Atom.to_string(key)
end
