defmodule Bandit.HTTP2.FlowControl do
  @moduledoc """
  Helpers for working with flow control window calculations
  """

  @max_window_increment Integer.pow(2, 31) - 1
  @max_window_size Integer.pow(2, 31) - 1
  @min_window_size Integer.pow(2, 30)

  def compute_recv_window(recv_window_size, data_size) do
    # This is what our window size will be after receiving data_size bytes
    recv_window_size = recv_window_size - data_size

    if recv_window_size > @min_window_size do
      # We have room to go before we need to update our window
      {recv_window_size, 0}
    else
      # We want our new window to be as large as possible, but are limited by both the maximum size
      # of the window (2^31-1) and the maximum size of the increment we can send to the client, both
      # per RFC7540§6.9. Be careful about handling cases where we have a negative window due to
      # misbehaving clients or network races
      new_recv_window_size = min(recv_window_size + @max_window_increment, @max_window_size)

      # Finally, determine what increment to send to the client
      increment = new_recv_window_size - recv_window_size

      {new_recv_window_size, increment}
    end
  end
end
