defmodule Certstream.Application do
  @moduledoc """
  Certstream is a service for watching CT servers, parsing newly discovered certificates,
  and broadcasting updates to connected websocket clients.
  """
  use Application

  def start(_type, _args) do
    port = get_port()

    children = [
      # Web services

      # Agents
      Certstream.ClientManager,
      Certstream.CertificateBuffer,

      # Watchers
      {DynamicSupervisor, name: WatcherSupervisor, strategy: :one_for_one},
      {Bandit, plug: Certstream.Router, scheme: :http, port: port}
    ]

    supervisor_info = Supervisor.start_link(children, strategy: :one_for_one)

    Certstream.CTWatcher.start_and_link_watchers(name: WatcherSupervisor)

    supervisor_info
  end

  defp get_port do
    case System.get_env("PORT") do
      nil -> 4000
      port_string -> port_string |> Integer.parse() |> elem(0)
    end
  end
end
