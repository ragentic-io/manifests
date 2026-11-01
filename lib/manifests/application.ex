defmodule Manifests.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ManifestsWeb.Telemetry,
      Manifests.Repo,
      {Oban,
       AshOban.config(
         Application.fetch_env!(:manifests, :ash_domains),
         Application.fetch_env!(:manifests, Oban)
       )},
      # Start a worker by calling: Manifests.Worker.start_link(arg)
      # {Manifests.Worker, arg},
      # Start to serve requests, typically the last entry
      {DNSCluster, query: Application.get_env(:manifests, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Manifests.PubSub},
      Manifests.Catalog.Loader,
      ManifestsWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Manifests.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ManifestsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
