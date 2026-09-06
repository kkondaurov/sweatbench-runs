defmodule GroupStay.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    maybe_replace_sandbox_pool()

    children = [
      GroupStayWeb.Telemetry,
      GroupStay.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:group_stay, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:group_stay, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: GroupStay.PubSub},
      # Start a worker by calling: GroupStay.Worker.start_link(arg)
      # {GroupStay.Worker, arg},
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

  defp serving?() do
    Application.get_env(:phoenix, :serve_endpoints) == true
  end

  defp maybe_replace_sandbox_pool() do
    repo_config = Application.get_env(:group_stay, GroupStay.Repo)

    if serving?() and repo_config[:pool] == Ecto.Adapters.SQL.Sandbox do
      server_config = [
        pool: DBConnection.ConnectionPool,
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
      ]

      Application.put_env(:group_stay, GroupStay.Repo, Keyword.merge(repo_config, server_config))
    end
  end

  defp skip_migrations?() do
    # Migrations run automatically when booting as a release or when the HTTP
    # server is started (mix phx.server), so a fresh database is ready to
    # serve. Other mix boots (tests, scripts) run migrations explicitly.
    serving = Application.get_env(:phoenix, :serve_endpoints) == true
    release = System.get_env("RELEASE_NAME") != nil
    not serving and not release
  end
end
