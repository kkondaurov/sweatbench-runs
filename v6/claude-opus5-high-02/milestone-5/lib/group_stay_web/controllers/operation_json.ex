defmodule GroupStayWeb.OperationJSON do
  @doc """
  The result remembered for an operation. The submission kept alongside it, and the order records
  were committed in, are audit material and are not exposed here.
  """
  def show(%{result: result}), do: %{data: result}

  def error(%{code: code}), do: %{error: %{code: code}}
end
