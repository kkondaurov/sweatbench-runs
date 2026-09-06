defmodule GroupStay.Operations.Canonical do
  @moduledoc """
  Canonical JSON rendering of a submitted operation payload.

  Two payloads are equivalent when they carry the same JSON values with object
  key order ignored and array order and values preserved. Rendering through
  `json/1` gives both submissions a byte-identical representation exactly when
  they are equivalent, so equivalence is a plain string comparison.
  """

  @spec json(term()) :: String.t()
  def json(term) do
    term
    |> normalize()
    |> Jason.encode!()
  end

  # Structs are not part of any JSON submission; pass them through so the
  # encoder fails loudly instead of silently flattening them.
  defp normalize(%mod{} = struct) when is_atom(mod), do: struct

  defp normalize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize(value)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value), do: value

  # Atom keys are accepted for internal callers; over HTTP Jason always
  # produces binary keys. Normalizing to binaries keeps both spellings equal.
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key) and not is_boolean(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_integer(key), do: Integer.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
