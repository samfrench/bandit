defmodule Bandit.HTTP2.Stream do
  @moduledoc """
  Carries out state management transitions per RFC7540§5.1. Anything having to do
  with the internal state of a stream is handled in this module. Note that sending
  of frames on behalf of a stream is a bit of a split responsibility: the stream
  itself may update state depending on the value of the end_stream flag (this is 
  a stream concern and thus handled here), but the sending of the data over the
  wire is a connection concern as it must be serialized properly & is subject to
  flow control at a connection level
  """

  defstruct stream_id: nil, state: nil, pid: nil, recv_window_size: 65_535

  require Integer
  require Logger

  alias Bandit.HTTP2.{Constants, FlowControl, StreamTask}

  @typedoc "An HTTP/2 stream identifier"
  @type stream_id :: non_neg_integer()

  @typedoc "An HTTP/2 stream state"
  @type state :: :idle | :open | :local_closed | :remote_closed | :closed

  @typedoc "A single HTTP/2 stream"
  @type t :: %__MODULE__{stream_id: stream_id(), state: state(), pid: pid() | nil}

  def recv_headers(%__MODULE__{} = stream, headers, peer, plug) do
    with :ok <- stream_is_idle(stream),
         :ok <- stream_id_is_valid(stream.stream_id),
         :ok <- headers_all_lowercase(headers, stream.stream_id),
         :ok <- pseudo_headers_all_request(headers, stream.stream_id),
         :ok <- pseudo_headers_first(headers, stream.stream_id),
         :ok <- no_connection_headers(headers, stream.stream_id),
         :ok <- valid_te_header(headers, stream.stream_id),
         :ok <- exactly_one_instance_of(headers, ":scheme", stream.stream_id),
         :ok <- exactly_one_instance_of(headers, ":method", stream.stream_id),
         :ok <- exactly_one_instance_of(headers, ":path", stream.stream_id),
         :ok <- non_empty_path(headers, stream.stream_id) do
      {:ok, pid} = StreamTask.start_link(self(), stream.stream_id, peer, headers, plug)
      {:ok, %{stream | state: :open, pid: pid}}
    end
  end

  defp stream_is_idle(stream) do
    if stream.state == :idle do
      :ok
    else
      {:error, {:connection, Constants.protocol_error(), "Received HEADERS when not in idle"}}
    end
  end

  # RFC7540§5.1.1 - client initiated streams must be odd
  defp stream_id_is_valid(stream_id) do
    if Integer.is_odd(stream_id) do
      :ok
    else
      {:error, {:connection, Constants.protocol_error(), "Received HEADERS with even stream_id"}}
    end
  end

  # RFC7540§8.1.2 - all headers name fields must be lowercsae
  defp headers_all_lowercase(headers, stream_id) do
    headers
    |> Enum.all?(fn {key, _value} -> String.downcase(key) == key end)
    |> if do
      :ok
    else
      {:error, {:stream, stream_id, Constants.protocol_error(), "Received uppercase header"}}
    end
  end

  # RFC7540§8.1.2.1 - only request pseudo headers may appear
  defp pseudo_headers_all_request(headers, stream_id) do
    headers
    |> Enum.all?(fn
      {":" <> key, _value} -> key in ~w[method scheme authority path]
      {_key, _value} -> true
    end)
    |> if do
      :ok
    else
      {:error, {:stream, stream_id, Constants.protocol_error(), "Received invalid pseudo header"}}
    end
  end

  # RFC7540§8.1.2.2 - pseudo headers must appear first
  defp pseudo_headers_first(headers, stream_id) do
    headers
    |> Enum.drop_while(fn {key, _value} -> String.starts_with?(key, ":") end)
    |> Enum.any?(fn {key, _value} -> String.starts_with?(key, ":") end)
    |> if do
      {:error,
       {:stream, stream_id, Constants.protocol_error(),
        "Received pseudo headers after regular one"}}
    else
      :ok
    end
  end

  # RFC7540§8.1.2.2 - no hop-by-hop headers from RFC2616§13.5.1
  # Note that we do not filter out the TE header here, since it is allowed in
  # specific cases by RFC7540§8.1.2.2. We check those cases in a separate filter
  defp no_connection_headers(headers, stream_id) do
    headers
    |> Enum.any?(fn {key, _value} ->
      key in ~w[connection keep-alive proxy-authenticate proxy-authorization trailers transfer-encoding upgrade]
    end)
    |> if do
      {:error,
       {:stream, stream_id, Constants.protocol_error(), "Received connection-specific header"}}
    else
      :ok
    end
  end

  # RFC7540§8.1.2.2 - TE header may be present if it contains exactly 'trailers'
  defp valid_te_header(headers, stream_id) do
    case List.keyfind(headers, "te", 0) do
      nil ->
        :ok

      {_, "trailers"} ->
        :ok

      _ ->
        {:error, {:stream, stream_id, Constants.protocol_error(), "Received invalid TE header"}}
    end
  end

  # RFC7540§8.1.2.3 - method, scheme, path pseudo headers must appear exactly once
  defp exactly_one_instance_of(headers, header, stream_id) do
    headers
    |> Enum.count(fn {key, _value} -> key == header end)
    |> case do
      1 ->
        :ok

      _ ->
        {:error, {:stream, stream_id, Constants.protocol_error(), "Expected 1 #{header} headers"}}
    end
  end

  # RFC7540§8.1.2.3 :path must not be empty
  defp non_empty_path(headers, stream_id) do
    case List.keyfind(headers, ":path", 0) do
      {_, ""} ->
        {:error, {:stream, stream_id, Constants.protocol_error(), "Received empty :path"}}

      _ ->
        :ok
    end
  end

  def recv_data(%__MODULE__{state: state} = stream, data) when state in [:open, :local_closed] do
    StreamTask.recv_data(stream.pid, data)

    {new_window, increment} =
      FlowControl.compute_recv_window(stream.recv_window_size, byte_size(data))

    {:ok, %{stream | recv_window_size: new_window}, increment}
  end

  def recv_data(%__MODULE__{} = stream, _data) do
    {:error, {:connection, Constants.protocol_error(), "Received DATA when in #{stream.state}"}}
  end

  def recv_rst_stream(%__MODULE__{state: :idle}, _error_code) do
    {:error, {:connection, Constants.protocol_error(), "Received RST_STREAM when in idle"}}
  end

  def recv_rst_stream(%__MODULE__{} = stream, error_code) do
    if is_pid(stream.pid), do: StreamTask.recv_rst_stream(stream.pid, error_code)
    {:ok, %{stream | state: :closed, pid: nil}}
  end

  def recv_end_of_stream(%__MODULE__{state: :open} = stream, true) do
    StreamTask.recv_end_of_stream(stream.pid)
    {:ok, %{stream | state: :remote_closed}}
  end

  def recv_end_of_stream(%__MODULE__{state: :local_closed} = stream, true) do
    StreamTask.recv_end_of_stream(stream.pid)
    {:ok, %{stream | state: :closed, pid: nil}}
  end

  def recv_end_of_stream(%__MODULE__{}, true) do
    {:error, {:connection, Constants.protocol_error(), "Received unexpected end_stream"}}
  end

  def recv_end_of_stream(%__MODULE__{} = stream, false) do
    {:ok, stream}
  end

  def owner?(%__MODULE__{pid: pid}, pid), do: :ok
  def owner?(%__MODULE__{}, _pid), do: {:error, :not_owner}

  def send_headers(%__MODULE__{state: state} = stream) when state in [:open, :remote_closed] do
    {:ok, stream}
  end

  def send_headers(%__MODULE__{}) do
    {:error, :invalid_state}
  end

  def send_data(%__MODULE__{state: state} = stream) when state in [:open, :remote_closed] do
    {:ok, stream}
  end

  def send_data(%__MODULE__{}) do
    {:error, :invalid_state}
  end

  def send_end_of_stream(%__MODULE__{state: :open} = stream, true) do
    {:ok, %{stream | state: :local_closed}}
  end

  def send_end_of_stream(%__MODULE__{state: :remote_closed} = stream, true) do
    {:ok, %{stream | state: :closed, pid: nil}}
  end

  def send_end_of_stream(%__MODULE__{}, true) do
    {:error, :invalid_state}
  end

  def send_end_of_stream(%__MODULE__{} = stream, false) do
    {:ok, stream}
  end

  def stream_terminated(%__MODULE__{state: :closed} = stream, :normal) do
    {:ok, %{stream | state: :closed, pid: nil}, nil}
  end

  def stream_terminated(%__MODULE__{} = stream, :normal) do
    Logger.warn("Stream #{stream.stream_id} completed in unepxected state #{stream.state}")

    {:ok, %{stream | state: :closed, pid: nil}, Constants.no_error()}
  end

  def stream_terminated(%__MODULE__{} = stream, reason) do
    Logger.error("Task for stream #{stream.stream_id} crashed with #{inspect(reason)}")

    {:ok, %{stream | state: :closed, pid: nil}, Constants.internal_error()}
  end
end
