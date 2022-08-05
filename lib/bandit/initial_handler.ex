defmodule Bandit.InitialHandler do
  @moduledoc false
  # The initial protocol implementation used for all connections. Switches to a
  # specific protocol implementation based on configuration, ALPN negotiation, and
  # line heuristics.

  use ThousandIsland.Handler

  # Attempts to guess the protocol in use, returning the applicable next handler and any
  # data consumed in the course of guessing which must be processed by the actual protocol handler
  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    {alpn_protocol(socket), sniff_wire(socket, state.read_timeout)}
    |> case do
      {Bandit.HTTP2.Handler, Bandit.HTTP2.Handler} ->
        {:switch, Bandit.HTTP2.Handler, state}

      {Bandit.HTTP1.Handler, {:no_match, data}} ->
        {:switch, Bandit.HTTP1.Handler, data, state}

      {:no_match, Bandit.HTTP2.Handler} ->
        {:switch, Bandit.HTTP2.Handler, state}

      {:no_match, {:no_match, data}} ->
        {:switch, Bandit.HTTP1.Handler, data, state}

      {_, {:error, error}} ->
        {:error, error}

      _other ->
        {:error, "Could not determine a protocol", state}
    end
  end

  # Returns the protocol as negotiated via ALPN, if applicable
  defp alpn_protocol(socket) do
    case ThousandIsland.Socket.negotiated_protocol(socket) do
      {:ok, "h2"} ->
        Bandit.HTTP2.Handler

      {:ok, "http/1.1"} ->
        Bandit.HTTP1.Handler

      _ ->
        Bandit.HTTP1.Handler
    end
  end

  # Returns the protocol as suggested by received data, if possible
  defp sniff_wire(socket, read_timeout) do
    case ThousandIsland.Socket.recv(socket, 24, read_timeout) do
      {:ok, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"} -> Bandit.HTTP2.Handler
      {:ok, data} -> {:no_match, data}
      {:error, error} -> {:error, error}
    end
  end
end
