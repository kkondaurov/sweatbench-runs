defmodule GroupStay.AccountingInitializer do
  @moduledoc false

  def child_spec(_options) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  def start_link do
    GroupStay.Accounting.ensure_all()
    :ignore
  end
end
