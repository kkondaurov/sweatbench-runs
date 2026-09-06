defmodule GroupStayWeb.PartnerBatchJSON do
  @doc """
  One result per submitted operation, in the order the operations were submitted.
  """
  def create(%{results: results}), do: %{results: results}

  def error(%{code: code}), do: %{error: %{code: code}}
end
