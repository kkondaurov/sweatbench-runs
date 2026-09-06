defmodule GroupStay.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    migrate()

    children = [
      GroupStayWeb.Telemetry,
      GroupStay.Repo,
      {DNSCluster, query: Application.get_env(:group_stay, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: GroupStay.PubSub},
      # Start to serve requests, typically the last entry
      GroupStayWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GroupStay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GroupStayWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp migrate do
    for repo <- Application.fetch_env!(:group_stay, :ecto_repos) do
      {:ok, _pid, _apps} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end

    :ok
  end
end
