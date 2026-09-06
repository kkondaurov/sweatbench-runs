defmodule GroupStayWeb.PartnerBatchJSON do
  @moduledoc false

  def render("show.json", %{results: results}) do
    %{results: results}
  end

  def render("invalid_batch.json", _assigns) do
    %{error: %{code: "invalid_batch"}}
  end
end
