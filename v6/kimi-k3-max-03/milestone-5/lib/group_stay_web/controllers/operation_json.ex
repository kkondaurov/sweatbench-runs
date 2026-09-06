defmodule GroupStayWeb.OperationJSON do
  @moduledoc false

  def render("show.json", %{result: result}) do
    %{data: result}
  end

  def render("not_found.json", _assigns) do
    %{error: %{code: "operation_not_found"}}
  end
end
