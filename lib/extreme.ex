defmodule Extreme do
  use GenServer
  alias Extreme.Request
  require Logger
  alias Extreme.Response

  ## Client API

  @doc """
  Starts connection to EventStore using `connection_settings` and optional `opts`.
  """
  def start_link(connection_settings, opts \\[]) do
    host = Keyword.fetch! connection_settings, :host
    port = Keyword.fetch! connection_settings, :port
    user = Keyword.fetch! connection_settings, :username
    pass = Keyword.fetch! connection_settings, :password
    GenServer.start_link __MODULE__, {host, port, user, pass}, opts
  end

  @doc """
  Executes protobuf `message` against `server`. Returns:

  - {:ok, protobuf_message} on success .
  - {:error, :not_authenticated} on wrong credentials.
  - {:error, error_reason, protobuf_message} on failure.
  """
  def execute(server, message) do
    GenServer.call server, {:execute, message}    
  end


  ## Server Callbacks

  def init({host, port, user, pass}) do
    opts = [:binary, active: :once]
    {:ok, socket} = String.to_char_list(host)
                    |> :gen_tcp.connect(port, opts)
    {:ok, %{socket: socket, pending_responses: %{}, credentials: %{user: user, pass: pass}, received_data: <<>>, should_receive: nil}}
  end

  def handle_call({:execute, protobuf_msg}, from, state) do
    {message, correlation_id} = Request.prepare protobuf_msg, state.credentials
    :ok = :gen_tcp.send state.socket, message
    state = put_in state.pending_responses, Map.put(state.pending_responses, correlation_id, from)
    {:noreply, state}
  end

  def handle_info({:tcp, socket, <<message_length :: 32-unsigned-little-integer, rest :: binary>>=msg}, %{socket: socket, received_data: <<>>} = state) do
    :inet.setopts(socket, active: :once) # Allow the socket to send us the next message
    if message_length == byte_size(rest) + byte_size(state.received_data) do 
      process_message(msg, state)
    else
      {:noreply, %{state | received_data: msg, should_receive: message_length + 4}}
    end
  end
  def handle_info({:tcp, socket, msg}, state) do
    :inet.setopts(socket, active: :once) # Allow the socket to send us the next message
    if state.should_receive == byte_size(msg) + byte_size(state.received_data) do 
      process_message(state.received_data <> msg, state)
    else
      {:noreply, %{state | received_data: state.received_data <> msg}}
    end
  end

  defp process_message(msg, state) do
    pending_responses = msg
                        |> Request.parse_response
                        |> respond(state)
    {:noreply, %{state | pending_responses: pending_responses, received_data: <<>>, should_receive: nil}}
  end

  defp respond({:heartbeat_request, correlation_id}, state) do
    message = Request.prepare :heartbeat_response, correlation_id
    :ok = :gen_tcp.send state.socket, message
    state.pending_responses
  end
  defp respond({:error, :not_authenticated, correlation_id}, state) do
    {:error, :not_authenticated}
    |> respond_with(correlation_id, state.pending_responses)
  end
  defp respond({_auth, correlation_id, response}, state) do
    response
    |> respond_with(correlation_id, state.pending_responses)
  end

  defp respond_with(response, correlation_id, pending_responses) do
    case Map.get(pending_responses, correlation_id) do
      nil -> 
        Logger.error "Can't find correlation_id #{correlation_id} for response #{inspect response}"
        pending_responses
      from -> 
        :ok = GenServer.reply(from, Response.reply(response))
        Map.delete pending_responses, correlation_id
    end
  end
end
