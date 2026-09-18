defmodule MCP.Transport.StreamableHTTP.ResponseReader do
  @moduledoc false

  alias MCP.Transport.StreamableHTTP.SecurityPolicy

  @pool_start_retry_delays [1, 2, 4, 8, 16]

  @spec request(keyword(), SecurityPolicy.t()) ::
          {:ok, Req.Response.t(), binary()}
          | {:stream, Req.Response.t()}
          | {:error, term()}
  def request(options, %SecurityPolicy{} = policy) when is_list(options) do
    stream? = Keyword.get(options, :stream, false)
    deadline = deadline(policy.request_timeout)

    options =
      options
      |> Keyword.delete(:stream)
      |> Keyword.merge(
        redirect: false,
        retry: false,
        raw: true,
        compressed: false,
        connect_options: [timeout: SecurityPolicy.connection_timeout(policy)],
        # `into: :self` returns as soon as the response headers arrive. Older
        # supported Req releases have no `:request_timeout` option, so this
        # cross-version adapter bounds that phase by clamping `:receive_timeout`
        # to the overall budget. The reader below enforces the total deadline
        # while consuming the body.
        receive_timeout: min_timeout(policy.receive_timeout, policy.request_timeout),
        into: :self
      )

    case request_with_pool_retry(options, deadline) do
      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        _ = Req.cancel_async_response(response)

        {:error,
         {:redirect_rejected, status, sanitized_location(header(response.headers, "location"))}}

      {:ok, %Req.Response{} = response} when stream? ->
        with :ok <- validate_content_encoding(response) do
          {:stream, response}
        end

      {:ok, %Req.Response{} = response} ->
        # Compression is disabled, so the wire and decoded bodies are the same
        # byte stream. Enforce the stricter configured boundary now rather than
        # accepting a decoded-limit option that has no effect.
        response_limit = SecurityPolicy.response_limit(policy)

        with :ok <- validate_content_encoding(response),
             :ok <- validate_content_length(response, response_limit),
             {:ok, body} <-
               consume_messages(
                 response,
                 response_limit,
                 policy.receive_timeout,
                 deadline,
                 0,
                 []
               ) do
          {:ok, %{response | body: body}, body}
        end

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :request_timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec consume(Req.Response.t(), pos_integer(), timeout(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  @doc """
  Consumes an asynchronous Req response from the calling process mailbox.

  Call this from an isolated request process: messages that do not belong to
  the response are ignored while the response is being drained.

  `receive_timeout` bounds the gap between chunks; `request_timeout` bounds the
  whole drain. Without the latter, a peer that drips one byte inside every
  receive window keeps the drain alive until `limit` bytes have arrived.
  """
  def consume(response, limit, receive_timeout, request_timeout \\ :infinity)
      when is_integer(limit) and limit > 0 and
             (is_integer(receive_timeout) or receive_timeout == :infinity) and
             (is_integer(request_timeout) or request_timeout == :infinity) do
    consume_messages(response, limit, receive_timeout, deadline(request_timeout), 0, [])
  end

  defp consume_messages(response, limit, receive_timeout, deadline, size, chunks) do
    timeout = next_timeout(receive_timeout, deadline)

    if timeout == 0 do
      _ = Req.cancel_async_response(response)
      {:error, :request_timeout}
    else
      receive do
        message ->
          case Req.parse_message(response, message) do
            {:ok, parsed} ->
              consume_chunks(response, parsed, limit, receive_timeout, deadline, size, chunks)

            {:error, reason} ->
              _ = Req.cancel_async_response(response)
              {:error, reason}

            :unknown ->
              consume_messages(response, limit, receive_timeout, deadline, size, chunks)
          end
      after
        timeout ->
          _ = Req.cancel_async_response(response)
          {:error, timeout_reason(receive_timeout, deadline)}
      end
    end
  end

  defp consume_chunks(response, parsed, limit, receive_timeout, deadline, size, chunks) do
    Enum.reduce_while(parsed, {:continue, size, chunks}, fn
      {:data, chunk}, {:continue, current_size, current_chunks} ->
        next_size = current_size + byte_size(chunk)

        if next_size > limit do
          _ = Req.cancel_async_response(response)
          {:halt, {:error, {:response_too_large, limit}}}
        else
          {:cont, {:continue, next_size, [chunk | current_chunks]}}
        end

      :done, {:continue, _current_size, current_chunks} ->
        {:halt, {:done, current_chunks}}

      {:trailers, _trailers}, accumulator ->
        {:cont, accumulator}
    end)
    |> case do
      {:continue, next_size, next_chunks} ->
        consume_messages(response, limit, receive_timeout, deadline, next_size, next_chunks)

      {:done, final_chunks} ->
        {:ok, final_chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Req 0.6.1 permits Finch 0.22, whose dynamically started pools can briefly
  # report :pool_not_available while their workers are still registering. Finch
  # raises before dispatch in that state, so this narrow retry cannot duplicate
  # an HTTP request and keeps the SDK's advertised Req 0.6.1 compatibility real.
  defp request_with_pool_retry(options, deadline),
    do: request_with_pool_retry(options, deadline, @pool_start_retry_delays)

  defp request_with_pool_retry(options, deadline, retry_delays) do
    case remaining_budget(deadline) do
      0 ->
        {:error, :request_timeout}

      remaining_budget ->
        options = clamp_request_timeouts(options, remaining_budget)
        try_request(options, deadline, retry_delays)
    end
  end

  defp try_request(options, deadline, retry_delays) do
    Req.request(options)
  rescue
    exception ->
      handle_request_exception(options, deadline, retry_delays, exception, __STACKTRACE__)
  end

  defp handle_request_exception(options, deadline, [delay | remaining], exception, stacktrace) do
    if finch_pool_not_available?(exception) do
      retry_pool_request(options, deadline, remaining, delay)
    else
      reraise exception, stacktrace
    end
  end

  defp handle_request_exception(_options, _deadline, [], exception, stacktrace) do
    if finch_pool_not_available?(exception),
      do: {:error, exception},
      else: reraise(exception, stacktrace)
  end

  defp retry_pool_request(options, deadline, remaining, delay) do
    if retry_delay_fits?(deadline, delay) do
      Process.sleep(delay)
      request_with_pool_retry(options, deadline, remaining)
    else
      {:error, :request_timeout}
    end
  end

  defp clamp_request_timeouts(options, :infinity), do: options

  defp clamp_request_timeouts(options, remaining_budget) do
    options
    |> Keyword.update!(:receive_timeout, &min_timeout(&1, remaining_budget))
    |> Keyword.update!(:connect_options, fn connect_options ->
      Keyword.update!(connect_options, :timeout, &min_timeout(&1, remaining_budget))
    end)
  end

  defp retry_delay_fits?(:infinity, _delay), do: true

  defp retry_delay_fits?(deadline, delay),
    do: deadline - System.monotonic_time(:millisecond) > delay

  defp remaining_budget(:infinity), do: :infinity
  defp remaining_budget(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp finch_pool_not_available?(%{__struct__: Finch.Error, reason: :pool_not_available}),
    do: true

  defp finch_pool_not_available?(_exception), do: false

  defp min_timeout(timeout, other), do: min(timeout, other)

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp next_timeout(:infinity, :infinity), do: :infinity
  defp next_timeout(timeout, :infinity), do: timeout

  defp next_timeout(:infinity, deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp next_timeout(timeout, deadline),
    do: min(timeout, max(deadline - System.monotonic_time(:millisecond), 0))

  defp timeout_reason(_receive_timeout, :infinity), do: :receive_timeout
  defp timeout_reason(:infinity, _deadline), do: :request_timeout

  defp timeout_reason(receive_timeout, deadline) do
    if deadline - System.monotonic_time(:millisecond) <= receive_timeout,
      do: :request_timeout,
      else: :receive_timeout
  end

  defp validate_content_encoding(response) do
    codings =
      response.headers
      |> header_values("content-encoding")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.downcase(&1) == "identity"))

    case codings do
      [] ->
        :ok

      unexpected ->
        _ = Req.cancel_async_response(response)
        {:error, {:unexpected_content_encoding, Enum.join(unexpected, ", ")}}
    end
  end

  defp validate_content_length(response, limit) do
    case header(response.headers, "content-length") do
      nil ->
        :ok

      value ->
        case Integer.parse(value) do
          {length, ""} when length <= limit -> :ok
          {length, ""} when length > limit -> cancel_too_large(response, limit)
          _invalid -> :ok
        end
    end
  end

  defp cancel_too_large(response, limit) do
    _ = Req.cancel_async_response(response)
    {:error, {:response_too_large, limit}}
  end

  defp header(headers, name) do
    headers
    |> header_values(name)
    |> List.first()
  end

  defp header_values(headers, name) do
    headers
    |> Enum.flat_map(fn {key, values} ->
      if String.downcase(key) == name, do: List.wrap(values), else: []
    end)
  end

  defp sanitized_location(nil), do: nil

  defp sanitized_location(location) do
    uri = URI.parse(location)
    URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
  end
end
