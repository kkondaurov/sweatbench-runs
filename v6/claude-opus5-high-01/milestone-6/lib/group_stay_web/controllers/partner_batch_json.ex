defmodule GroupStayWeb.PartnerBatchJSON do
  @moduledoc "Renders one result per submitted operation, in the submitted order."

  def create(%{results: results}), do: %{results: results}
end
