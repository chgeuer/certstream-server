#!/usr/bin/env elixir

Mix.install(
  [
    {:websockex, "~> 0.4.3"},
    {:req, "~> 0.4.14"},
    {:jason_native, "~> 0.1.0"}
  ],
  start_applications: true
)

defmodule WebSocketExample do
  use WebSockex

  def start_link(url \\ "http://localhost:4000/") do
    WebSockex.start_link(url, __MODULE__, nil)
  end

  def handle_frame({:text, msg}, state) do
    %{
      "message_type" => _message_type,
      "data" => %{
        "cert_index" => _cert_index,
        "cert_link" => _cert_link,
        "leaf_cert" => %{
          "all_domains" => _all_domains,
          "extensions" => _extensions,
          "fingerprint" => fingerprint,
          "issuer" => %{"O" => issuer_o} = _issuer,
          "not_after" => _not_after,
          "not_before" => _not_before,
          "serial_number" => _serial_number,
          "signature_algorithm" => _signature_algoritm,
          "subject" => _subject
        },
        "seen" => _seen,
        "source" => %{
          "name" => source_name,
          "url" => _source_url
        },
        "update_type" => _update_type
      }
    } = Jason.decode!(msg)
    
    IO.puts "#{source_name}: #{issuer_o} (#{fingerprint})"
    {:ok, state}
  end

  def handle_cast({:send, {type, msg} = frame}, state) do
    IO.puts "Sending #{type} frame with payload: #{msg}"
    {:reply, frame, state}
  end

  def start(url \\ "http://localhost:4000/") do
    case __MODULE__.start_link(url) do
      {:error, reason} ->
        IO.puts("Not yet ready.... #{inspect reason}")
        Process.sleep(500)
        start(url)
      {:ok, pid} -> {:ok, pid}
    end
  end
end

{:ok, _pid} = WebSocketExample.start()

Process.sleep(:infinity)
