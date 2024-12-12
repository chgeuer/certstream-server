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

  # @impl WebSock
  # def handle_info(
  #       {:mail, box_pid, serialized_certificates, _message_count, message_drop_count},
  #       state
  #     ) do
  #   if message_drop_count > 0 do
  #     Instruments.increment("certstream.dropped_messages", message_drop_count,
  #       tags: ["ip:#{state.ip_address}"]
  #     )
  #
  #     Logger.warning("Message drop count greater than 0 -> #{message_drop_count}")
  #   end
  #
  #   Logger.debug(fn ->
  #     "Sending client #{length(serialized_certificates |> List.flatten())} client frames"
  #   end)
  #
  #   # Reactivate our pobox active mode
  #   :pobox.active(box_pid, fn msg, _ -> {{:ok, msg}, :nostate} end, :nostate)
  #
  #   messages =
  #     serialized_certificates
  #     |> List.flatten()
  #     |> Enum.map(fn msg -> {:text, msg} end)
  #
  #   Enum.reduce(messages, {:ok, state}, fn
  #     msg, {:ok, state} -> {:push, msg, state}
  #   end)
  # end

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

defmodule Certstream.CTParser do
  @moduledoc false

  @log_entry_types %{
    0 => :X509LogEntry,
    1 => :PrecertLogEntry
  }

  def parse_entry(entry) do
    leaf_input = Base.decode64!(entry["leaf_input"])
    extra_data = Base.decode64!(entry["extra_data"])

    <<
      _version::integer,
      _leaf_type::integer,
      _timestamp::size(64),
      type::size(16),
      entry::binary
    >> = leaf_input

    entry_type = @log_entry_types[type]

    cert = %{:update_type => entry_type}

    [top | rest] =
      [
        parse_leaf_entry(entry_type, entry),
        parse_extra_data(entry_type, extra_data)
      ]
      |> List.flatten()

    cert
    |> Map.put(:leaf_cert, top)
    |> Map.put(:chain, rest)
  end

  defp parse_extra_data(:X509LogEntry, extra_data) do
    <<_chain_length::size(24), chain::binary>> = extra_data
    parse_certificate_chain(chain, [])
  end

  defp parse_extra_data(:PrecertLogEntry, extra_data) do
    <<
      length::size(24),
      certificate_data::binary-size(length),
      _chain_length::size(24),
      extra_chain::binary
    >> = extra_data

    [
      parse_certificate(certificate_data, :leaf),
      parse_certificate_chain(extra_chain, [])
    ]
  end

  defp format_crl_point({:DistributionPoint, {:fullName, points}, _, _}) do
    points
    |> Enum.map(fn
      {:uniformResourceIdentifier, url} ->
        to_string(url)

      {:directoryName, _} ->
        # Skip directory names for now
        nil

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_crl_point(_), do: nil

  # Then use this in your certificate parsing logic where you handle extensions:
  defp parse_certificate(certificate_data, type) do
    case type do
      :leaf ->
        cert = EasySSL.parse_der(certificate_data, serialize: true, all_domains: true)
        # Handle CRL points if present in extensions
        cert =
          case cert do
            %{extensions: %{crlDistributionPoints: points}} when is_tuple(points) ->
              put_in(cert, [:extensions, :crlDistributionPoints], format_crl_point(points))

            _ ->
              cert
          end

        cert

      :chain ->
        EasySSL.parse_der(certificate_data, serialize: true)
    end
  end

  defp parse_certificate_chain(
         <<size::size(24), certificate_data::binary-size(size), rest::binary>>,
         entries
       ) do
    parse_certificate_chain(rest, [parse_certificate(certificate_data, :chain) | entries])
  end

  defp parse_certificate_chain(<<>>, entries) do
    entries |> Enum.reverse()
  end

  defp parse_leaf_entry(
         :X509LogEntry,
         <<length::size(24), certificate_data::binary-size(length), _extensions::size(16)>>
       ) do
    parse_certificate(certificate_data, :leaf)
  end

  # For now we don't parse these and rely on everything in "extra_data" only
  defp parse_leaf_entry(:PrecertLogEntry, _entry) do
    []
  end
end

defmodule Certstream.CTWatcher do
  @moduledoc """
  The GenServer responsible for watching a specific CT server.

  It ticks every 10 seconds and regularly checks to see if there are any certificates to fetch and broadcast.
  """
  use GenServer
  use Instruments
  require Logger

  defstruct req: nil,
            update_interval_seconds: 10,
            operator: nil,
            url: nil,
            batch_size: nil,
            tree_size: nil,
            processed_count: 0

  def start_and_link_watchers(name: supervisor_name) do
    Logger.info("Initializing #{__MODULE__}...")

    req = req_new()

    # Fetch all CT lists with a longer timeout
    case Req.get(req,
           url: "https://www.gstatic.com/ct/log_list/v3/all_logs_list.json",
           retry: :safe_transient,
           max_retries: 3,
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"operators" => operators}}} ->
        process_operators(operators, req, supervisor_name)

      error ->
        Logger.error("Failed to fetch CT log list: #{inspect(error)}")
        # Return empty list to allow application to continue starting
        []
    end
  end

  defp process_operators(operators, req, supervisor_name) do
    operators
    |> Enum.flat_map(fn %{"logs" => logs, "name" => operator_name} ->
      Enum.map(logs, &Map.put(&1, "operator_name", operator_name))
    end)
    |> Enum.filter(fn
      %{"state" => %{"rejected" => _}} -> false
      _ -> true
    end)
    |> Enum.each(fn log ->
      # Start each watcher in a separate task to prevent one failure from blocking others
      Task.start(fn ->
        case verify_log_availability(log["url"], req) do
          true ->
            state = %__MODULE__{
              operator: log,
              update_interval_seconds: 10,
              req: req |> Req.merge(base_url: log["url"]),
              url: log["url"]
            }

            case DynamicSupervisor.start_child(supervisor_name, child_spec(state)) do
              {:ok, _pid} ->
                Logger.info("Started watcher for #{log["url"]}")

              {:error, error} ->
                Logger.warning("Failed to start watcher for #{log["url"]}: #{inspect(error)}")
            end

          false ->
            Logger.info("Skipping inactive log: #{log["url"]}")
        end
      end)
    end)
  end

  defp verify_log_availability(url, req) do
    merged_req =
      req
      |> Req.merge(
        base_url: url,
        connect_options: [timeout: 10_000],
        # Don't retry for verification
        retry: false
      )

    try do
      case Req.get(merged_req, url: "ct/v1/get-sth") do
        {:ok, %Req.Response{status: 200}} ->
          true

        {:ok, _} ->
          false

        {:error, %Req.TransportError{reason: :nxdomain}} ->
          false

        {:error, _} ->
          false
      end
    rescue
      e ->
        Logger.debug("Error verifying #{url}: #{inspect(e)}")
        false
    end
  end

  def child_spec(state) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [state]},
      # restart: :permanent
      restart: :transient
    }
  end

  def start_link(state) do
    GenServer.start_link(__MODULE__, state)
  end

  def init(%__MODULE__{} = state) do
    Process.set_label("#{__MODULE__} for #{state.url}")

    {:ok, state, {:continue, :finish_init}}
  end

  def handle_continue(:finish_init, %__MODULE__{} = state) do
    # Schedule the initial update to happen between 0 and 3 seconds from now in
    # Process.sleep(:rand.uniform(3_000))

    # On first run attempt to fetch 512 certificates, and see what the API returns. However
    # many certs come back is what we should use as the batch size moving forward (at least
    # in theory).

    case Req.get(state.req, url: "ct/v1/get-entries?start=0&end=511") do
      {:ok, %Req.Response{status: 200, body: %{"entries" => entries}}} ->
        batch_size = Enum.count(entries)

        Logger.info(
          "#{:proc_lib.get_label(self())} with url #{state.url} found batch size of #{batch_size}."
        )

        state = %__MODULE__{
          state
          | batch_size: batch_size,
            # On first run populate the state.tree_size key
            tree_size: get_tree_size(state)
        }

        send(self(), :update)

        {:noreply, state}

      {:error, %Req.TransportError{reason: :nxdomain}} ->
        Logger.error(
          "#{__MODULE__} for #{state.url} terminating cause hostname not found (:nxdomain)"
        )

        {:stop, :normal, state}

      {:ok, %Req.Response{status: 404}} ->
        Logger.error("#{__MODULE__} for #{state.url} terminating because not found (HTTP 404)")
        {:stop, :normal, state}
    end

    # rescue
    #   e ->
    #     Logger.warning("#{:proc_lib.get_label(self())} blew up because #{inspect(e)}")
    #     {:noreply, state}
    # end
  end

  def get_tree_size(%__MODULE__{} = state) do
    %Req.Response{status: 200, body: %{"tree_size" => tree_size}} =
      Req.get!(state.req, url: "ct/v1/get-sth")

    tree_size
  end

  def handle_info({:ssl_closed, _}, state) do
    Logger.info("#{:proc_lib.get_label(self())} got :ssl_closed message. Ignoring.")
    {:noreply, state}
  end

  def handle_info(:update, %__MODULE__{} = state) do
    Logger.debug(fn -> "#{:proc_lib.get_label(self())} got tick." end)

    current_tree_size = get_tree_size(state)

    Logger.debug(fn -> "Tree size #{current_tree_size} - #{state.tree_size}" end)

    state =
      case current_tree_size > state.tree_size do
        true ->
          Logger.info(
            "#{:proc_lib.get_label(self())} with url #{state.url} found #{current_tree_size - state.tree_size} certificates [#{state.tree_size} -> #{current_tree_size}]."
          )

          cert_count = current_tree_size - state.tree_size
          Instruments.increment("certstream.worker", cert_count, tags: ["url:#{state.url}"])

          Instruments.increment("certstream.aggregate_owners_count", cert_count,
            tags: [~s(owner:#{state.operator["operator_name"]})]
          )

          broadcast_updates(state, current_tree_size)

          %__MODULE__{
            state
            | tree_size: current_tree_size,
              processed_count: state.processed_count + current_tree_size - state.tree_size
          }

        false ->
          state
      end

    Process.send_after(self(), :update, trunc(:timer.seconds(state.update_interval_seconds)))

    {:noreply, state}
  end

  # defp broadcast_updates(state, current_size) do
  #   certificate_count = current_size - state.tree_size
  #   certificates = Enum.to_list((current_size - certificate_count)..(current_size - 1))
  #
  #   # Logger.info("Certificate count - #{certificate_count} ")
  #
  #   certificates
  #   |> Enum.chunk_every(state.batch_size)
  #   # Use Task.async_stream to have 5 concurrent requests to the CT server to fetch
  #   # our certificates without waiting on the previous chunk.
  #   |> Task.async_stream(&fetch_and_broadcast_certs(&1, state),
  #     max_concurrency: 5,
  #     timeout: :timer.seconds(600)
  #   )
  #   # Nop to just pull the requests through async_stream
  #   |> Enum.to_list()
  # end
  #
  # def fetch_and_broadcast_certs(ids, state) do
  #   Logger.debug(fn -> "Attempting to retrieve #{ids |> Enum.count()} entries" end)
  #
  #   {startIndex, endIndex} =
  #     case ids do
  #       [] -> {0, 1}
  #       [single] -> {single, single + 1}
  #       _ -> {List.first(ids), List.last(ids)}
  #     end
  #
  #   url = "ct/v1/get-entries?start=#{startIndex}&end=#{endIndex}"
  #
  #   entries =
  #     case Req.get!(state.req, url: url) do
  #       %Req.Response{status: 200, body: %{"entries" => entries}} ->
  #         entries
  #
  #       response ->
  #         # https://doowon.github.io/2020/07/09/retrieving_certificates_from_certificate_transparency.html
  #         #
  #         # Failed to fetch entries from https://ct2025-b.trustasia.com/log2025b/ct/v1/get-entries?start=1101396&end=1101396
  #         # IDs: [1101396]
  #         # %Req.Response{status: 400, body: "Bad Request need tree size: 1101397 to get leaves but only got: 1101396"}
  #         Logger.error(fn ->
  #           "Failed to fetch entries from #{state.url}#{url} (IDs: #{inspect(ids)}: #{inspect(response)}"
  #         end)
  #
  #         []
  #     end
  #
  #   entries
  #   |> Enum.zip(ids)
  #   |> Enum.map(fn {entry, cert_index} ->
  #     entry
  #     |> Certstream.CTParser.parse_entry()
  #     |> Map.merge(%{
  #       :cert_index => cert_index,
  #       :seen => :os.system_time(:microsecond) / 1_000_000,
  #       :source => %{
  #         :url => state.operator["url"],
  #         :name => state.operator["description"]
  #       },
  #       :cert_link =>
  #         "#{state.operator["url"]}ct/v1/get-entries?start=#{cert_index}&end=#{cert_index}"
  #     })
  #   end)
  #   |> Certstream.ClientManager.broadcast_to_clients()
  #
  #   entry_count = Enum.count(entries)
  #   batch_count = Enum.count(ids)
  #
  #   # If we have *unequal* counts the API has returned less certificates than our initial batch
  #   # heuristic. Drop the entires we retrieved and recurse to fetch others.
  #   if entry_count != batch_count do
  #     Logger.debug(fn ->
  #       "We didn't retrieve all the entries for this batch, fetching missing #{batch_count - entry_count} entries"
  #     end)
  #
  #     fetch_and_broadcast_certs(ids |> Enum.drop(Enum.count(entries)), state)
  #   end
  # end

  def broadcast_updates(state, current_size) do
    certificate_count = current_size - state.tree_size
    certificates = Enum.to_list((current_size - certificate_count)..(current_size - 1))

    certificates
    |> Enum.chunk_every(state.batch_size)
    |> Task.async_stream(
      &fetch_and_broadcast_certs(&1, state),
      max_concurrency: 5,
      timeout: :timer.seconds(600),
      # Add this to handle timeouts gracefully
      on_timeout: :kill_task
    )
    |> Enum.reduce_while([], fn
      {:ok, result}, acc ->
        {:cont, [result | acc]}

      {:exit, :timeout}, acc ->
        Logger.warning("Timeout while processing certificates from #{state.url}")
        # Continue processing despite timeout
        {:cont, acc}
    end)
  end

  # Also modify fetch_and_broadcast_certs to handle failures more gracefully
  def fetch_and_broadcast_certs(ids, state) do
    Logger.debug(fn -> "Attempting to retrieve #{ids |> Enum.count()} entries" end)

    try do
      {startIndex, endIndex} =
        case ids do
          [] -> {0, 1}
          [single] -> {single, single + 1}
          _ -> {List.first(ids), List.last(ids)}
        end

      url = "ct/v1/get-entries?start=#{startIndex}&end=#{endIndex}"

      # Add timeout
      entries =
        case Req.get(state.req, url: url, receive_timeout: 30_000) do
          {:ok, %Req.Response{status: 200, body: %{"entries" => entries}}} ->
            entries

          response ->
            Logger.error(fn ->
              "Failed to fetch entries from #{state.url}#{url} (IDs: #{inspect(ids)}: #{inspect(response)}"
            end)

            []
        end

      # Process entries if we got any
      unless Enum.empty?(entries) do
        entries
        |> Enum.zip(ids)
        |> Enum.map(fn {entry, cert_index} ->
          entry
          |> Certstream.CTParser.parse_entry()
          |> Map.merge(%{
            :cert_index => cert_index,
            :seen => :os.system_time(:microsecond) / 1_000_000,
            :source => %{
              :url => state.operator["url"],
              :name => state.operator["description"]
            },
            :cert_link =>
              "#{state.operator["url"]}ct/v1/get-entries?start=#{cert_index}&end=#{cert_index}"
          })
        end)
        |> Certstream.ClientManager.broadcast_to_clients()
      end
    rescue
      e ->
        Logger.error("Error processing certificates: #{inspect(e)}")
        # Return empty list on error
        []
    end
  end

  defp req_new do
    Req.new(
      # https://hexdocs.pm/req/Req.Steps.html#retry/1
      retry: :safe_transient,
      retry_delay: 10_000,
      redirect: true,
      max_redirects: 5,
      connect_options: [
        transport_opts: [
          timeout: 10_000,
          versions: tls_versions()
        ]
      ]
    )
    |> Req.Request.put_header("User-Agent", user_agent())
  end

  defp tls_versions do
    case Application.fetch_env(:certstream, :tls_versions) do
      {:ok, other} -> other
      :error -> [:"tlsv1.2"]
    end
  end

  # Allow the user agent to be overridden in the config, or use a default Certstream identifier
  defp user_agent do
    case Application.fetch_env(:certstream, :user_agent) do
      {:ok, val} -> val
      :error -> "Certstream Server v#{Application.spec(:certstream, :vsn)}"
    end
  end
end

defmodule Certstream.ClientManager do
  @moduledoc """
  An agent responsible for managing and broadcasting to websocket clients. Uses :pobox to
  provide buffering and eventually drops messages if the backpressure isn't enough.
  """
  use Agent
  require Logger

  def start_link(_opts) do
    Logger.info("Starting #{__MODULE__}...")
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def add_client(client_pid, client_state) do
    {:ok, box_pid} = :pobox.start_link(client_pid, 500, :queue)

    :pobox.active(box_pid, fn msg, _ -> {{:ok, msg}, :nostate} end, :nostate)

    Agent.update(
      __MODULE__,
      &Map.put(
        &1,
        client_pid,
        client_state |> Map.put(:po_box, box_pid)
      )
    )
  end

  def remove_client(client_pid) do
    Agent.update(__MODULE__, fn state ->
      # Remove our pobox
      state |> Map.get(client_pid) |> Map.get(:po_box) |> Process.exit(:kill)

      # Remove client from state map
      state |> Map.delete(client_pid)
    end)
  end

  def get_clients do
    Agent.get(__MODULE__, fn state -> state end)
  end

  def get_client_count do
    Agent.get(__MODULE__, fn state -> state |> Map.keys() |> length end)
  end

  def get_clients_json do
    Agent.get(__MODULE__, fn state ->
      state
      |> Enum.map(fn {k, v} ->
        coerced_payload =
          v
          |> Map.update!(:connect_time, &DateTime.to_iso8601/1)
          |> Map.drop([:po_box, :is_websocket])

        {inspect(k), coerced_payload}
      end)
      |> Enum.into(%{})
    end)
  end

  def broadcast_to_clients(entries) do
    Logger.debug(fn -> "Broadcasting #{length(entries)} certificates to clients" end)

    certificates =
      entries
      |> Enum.map(&%{:message_type => "certificate_update", :data => &1})

    serialized_certificates_full =
      certificates
      |> Enum.map(&Jason.encode!/1)

    certificates_lite =
      certificates
      |> Enum.map(&remove_chain_from_cert/1)
      |> Enum.map(&remove_der_from_cert/1)

    Certstream.CertificateBuffer.add_certs_to_buffer(certificates_lite)

    serialized_certificates_lite =
      certificates_lite
      |> Enum.map(&Jason.encode!/1)

    dns_entries_only =
      certificates
      |> Enum.map(&get_in(&1, [:data, :leaf_cert, :all_domains]))
      |> Enum.map(fn dns_entries -> %{:message_type => "dns_entries", :data => dns_entries} end)
      |> Enum.map(&Jason.encode!/1)

    get_clients()
    |> Enum.each(fn {_, client_state} ->
      case client_state.path do
        "/full-stream" -> send_bundle(serialized_certificates_full, client_state.po_box)
        "/full-stream/" -> send_bundle(serialized_certificates_full, client_state.po_box)
        "/domains-only" -> send_bundle(dns_entries_only, client_state.po_box)
        "/domains-only/" -> send_bundle(dns_entries_only, client_state.po_box)
        _ -> send_bundle(serialized_certificates_lite, client_state.po_box)
      end
    end)
  end

  def send_bundle(entries, po_box) do
    :pobox.post(po_box, entries)
  end

  def remove_chain_from_cert(cert) do
    cert
    |> pop_in([:data, :chain])
    |> elem(1)
  end

  def remove_der_from_cert(cert) do
    # Clean the der field from the leaf cert
    cert
    |> pop_in([:data, :leaf_cert, :as_der])
    |> elem(1)
  end
end

defmodule Certstream.CertificateBuffer do
  use Agent
  use Instruments
  require Logger

  @moduledoc """
    An agent designed to ring-buffer certificate updates as they come in so the most recent 25 certificates can be
    aggregated for the /example.json and /latest.json routes.
  """

  @doc "Starts the CertificateBuffer agent and creates an ETS table for tracking the certificates processed"
  def start_link(_opts) do
    Logger.info("Starting #{__MODULE__}...")

    Agent.start_link(
      fn ->
        :ets.new(:counter, [:named_table, :public])
        :ets.insert(:counter, processed_certificates: 0)
        []
      end,
      name: __MODULE__
    )
  end

  @doc "Adds a certificate update to the circular certificate buffer"
  def add_certs_to_buffer(certificates) do
    cert_count = length(certificates)

    :ets.update_counter(:counter, :processed_certificates, cert_count)
    Instruments.increment("certstream.all.processed_certificates", cert_count)

    Agent.update(__MODULE__, fn state ->
      state = certificates ++ state
      state |> Enum.take(25)
    end)
  end

  @doc "The number of certificates processed"
  def get_processed_certificates do
    :ets.lookup(:counter, :processed_certificates)
    |> Keyword.get(:processed_certificates)
  end

  @doc "Gets the latest certificate seen by Certstream, indented with 4 spaces"
  def get_example_json do
    Agent.get(
      __MODULE__,
      &Jason.encode!(List.first(&1), pretty: true)
    )
  end

  @doc "Gets the latest 25 certficates seen by Certstream, indented with 4 spaces"
  def get_latest_json do
    Agent.get(
      __MODULE__,
      &Jason.encode!(%{messages: &1}, pretty: true)
    )
  end
end
