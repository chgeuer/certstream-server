defmodule Certstream.Router do
  @moduledoc """
  HTTP router for the CertStream server.
  """
  use Plug.Router
  use Instruments
  require Logger

  plug(:match)
  plug(:dispatch)

  plug(Plug.Static,
    at: "/static",
    from: {:certstream, "frontend/dist/static"}
  )

  get "/example.json" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Certstream.CertificateBuffer.get_example_json())
  end

  get "/latest.json" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Certstream.CertificateBuffer.get_latest_json())
  end

  get "/stats" do
    response = %{
      processed_certificates: Certstream.CertificateBuffer.get_processed_certificates(),
      current_users: Certstream.ClientManager.get_clients_json()
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response, pretty: true))
  end

  # get "/full-stream" do
  #   conn
  #   |> WebSockAdapter.upgrade(Certstream.Socket, %{conn: conn}, timeout: 60_000)
  # end
  #
  # get "/domains-only" do
  #   conn
  #   |> WebSockAdapter.upgrade(Certstream.Socket, %{conn: conn}, timeout: 60_000)
  # end

  get "/" do
    Instruments.increment("certstream.index_load", 1, tags: ["ip:#{client_ip(conn)}"])

    if get_req_header(conn, "upgrade") == ["websocket"] do
      conn
      |> WebSockAdapter.upgrade(Certstream.Socket, %{conn: conn}, timeout: 60_000)
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, File.read!("frontend/dist/index.html"))
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp client_ip(conn) do
    conn.remote_ip |> :inet_parse.ntoa() |> to_string()
  end
end
