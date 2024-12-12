defmodule Certstream.Socket do
  @moduledoc """
  WebSocket handler for certificate streaming using WebSock behaviour.
  """
  @behaviour WebSock
  use Instruments
  require Logger

  @impl WebSock
  def init(%{conn: conn} = _options) do
    client_state = %{
      is_websocket: true,
      connect_time: DateTime.utc_now(),
      ip_address: conn.remote_ip |> :inet_parse.ntoa() |> to_string(),
      path: conn.request_path,
      headers: conn.req_headers
    }

    Logger.info("Client connected #{inspect(client_state.ip_address)}")

    Instruments.increment("certstream.websocket_connect", 1,
      tags: ["ip:#{client_state.ip_address}"]
    )

    Certstream.ClientManager.add_client(self(), client_state)

    {:ok, client_state}
  end

  @impl WebSock
  def handle_control(:established, state) do
    Logger.debug("WebSocket connection established")
    {:ok, state}
  end

  @impl WebSock
  def handle_in({text, _opcode}, state) do
    Logger.debug(fn -> "Client sent message #{inspect(text)}" end)
    Instruments.increment("certstream.websocket_msg_in", 1, tags: ["ip:#{state.ip_address}"])
    {:ok, state}
  end

  @impl WebSock
  def handle_info(
        {:mail, box_pid, serialized_certificates, _message_count, message_drop_count},
        state
      ) do
    if message_drop_count > 0 do
      Instruments.increment("certstream.dropped_messages", message_drop_count,
        tags: ["ip:#{state.ip_address}"]
      )

      Logger.warning("Message drop count greater than 0 -> #{message_drop_count}")
    end

    # Reactivate our pobox active mode
    :pobox.active(box_pid, fn msg, _ -> {{:ok, msg}, :nostate} end, :nostate)

    # Handle the flattened list of messages
    messages = List.flatten(serialized_certificates)

    # Return all messages as a list of frames
    {:push, Enum.map(messages, &{:text, &1}), state}
  end

  @impl WebSock
  def terminate(_reason, state) do
    if state[:is_websocket] do
      Instruments.increment("certstream.websocket_disconnect", 1,
        tags: ["ip:#{state[:ip_address]}"]
      )

      Logger.debug(fn -> "Client disconnected #{inspect(state.ip_address)}" end)
      Certstream.ClientManager.remove_client(self())
    end

    :ok
  end
end
