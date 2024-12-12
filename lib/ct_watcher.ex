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
