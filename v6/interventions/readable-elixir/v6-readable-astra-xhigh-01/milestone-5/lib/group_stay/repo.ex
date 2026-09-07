defmodule GroupStay.Repo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  # Exqlite prepares every execution anew. Ecto's shared query cache still retains
  # native statement references from earlier connections; releasing one can block
  # on that connection's write-lock wait and stall the active writer. Keep those
  # references local to each query so concurrent immediate transactions progress.
  def default_options(_operation), do: [query_cache: false]
end
