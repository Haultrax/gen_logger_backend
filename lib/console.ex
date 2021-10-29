defmodule GenLoggerBackend.Console do
  def init(config, state) do
    level = Keyword.get(config, :level)
    device = Keyword.get(config, :device, :user)
    format = Logger.Formatter.compile(Keyword.get(config, :format))
    colors = configure_colors(config)
    metadata = Keyword.get(config, :metadata, []) |> configure_metadata()
    max_buffer = Keyword.get(config, :max_buffer, 32)

    %{
      state
      | format: format,
        metadata: metadata,
        level: level,
        colors: colors,
        device: device,
        max_buffer: max_buffer
    }
  end

  defp configure_metadata(:all), do: :all
  defp configure_metadata(metadata), do: Enum.reverse(metadata)


  defp configure_colors(config) do
    colors = Keyword.get(config, :colors, [])

    %{
      debug: Keyword.get(colors, :debug, :cyan),
      info: Keyword.get(colors, :info, :normal),
      warn: Keyword.get(colors, :warn, :yellow),
      error: Keyword.get(colors, :error, :red),
      enabled: Keyword.get(colors, :enabled, IO.ANSI.enabled?())
    }
  end

  def handle_event(level, msg, ts, md, state) do
    %{ref: ref, buffer_size: buffer_size, max_buffer: max_buffer} = state

    cond do
      is_nil(ref) ->
        {:ok, log_event(level, msg, ts, md, state)}

      buffer_size < max_buffer ->
        {:ok, buffer_event(level, msg, ts, md, state)}

      buffer_size === max_buffer ->
        state = buffer_event(level, msg, ts, md, state)
        {:ok, await_io(state)}
    end
  end

  defp log_event(level, msg, ts, md, %{device: device} = state) do
    output = format_event(level, msg, ts, md, state)
    %{state | ref: async_io(device, output), output: output}
  end

  defp buffer_event(level, msg, ts, md, state) do
    %{buffer: buffer, buffer_size: buffer_size} = state
    buffer = [buffer | format_event(level, msg, ts, md, state)]
    %{state | buffer: buffer, buffer_size: buffer_size + 1}
  end

  defp async_io(name, output) when is_atom(name) do
    case Process.whereis(name) do
      device when is_pid(device) ->
        async_io(device, output)

      nil ->
        raise "no device registered with the name #{inspect(name)}"
    end
  end

  defp async_io(device, output) when is_pid(device) do
    ref = Process.monitor(device)
    send(device, {:io_request, self(), ref, {:put_chars, :unicode, output}})
    ref
  end

  defp await_io(%{ref: nil} = state), do: state

  defp await_io(%{ref: ref} = state) do
    receive do
      {:io_reply, ^ref, :ok} ->
        handle_io_reply(:ok, state)

      {:io_reply, ^ref, error} ->
        handle_io_reply(error, state)
        |> await_io()

      {:DOWN, ^ref, _, pid, reason} ->
        raise "device #{inspect(pid)} exited: " <> Exception.format_exit(reason)
    end
  end

  defp format_event(level, msg, ts, md, state) do
    %{format: format, metadata: keys, colors: colors} = state

    format
    |> Logger.Formatter.format(level, msg, ts, take_metadata(md, keys))
    |> color_event(level, colors, md)
  end

  defp take_metadata(metadata, :all) do
    metadata
  end

  defp take_metadata(metadata, keys) do
    Enum.reduce(keys, [], fn key, acc ->
      case Keyword.fetch(metadata, key) do
        {:ok, val} -> [{key, val} | acc]
        :error -> acc
      end
    end)
  end

  defp color_event(data, _level, %{enabled: false}, _md), do: data

  defp color_event(data, level, %{enabled: true} = colors, md) do
    color = md[:ansi_color] || Map.fetch!(colors, level)
    [IO.ANSI.format_fragment(color, true), data | IO.ANSI.reset()]
  end

  defp log_buffer(%{buffer_size: 0, buffer: []} = state), do: state

  defp log_buffer(state) do
    %{device: device, buffer: buffer} = state
    %{state | ref: async_io(device, buffer), buffer: [], buffer_size: 0, output: buffer}
  end

  def handle_io_reply(:ok, %{ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    log_buffer(%{state | ref: nil, output: nil})
  end

  def handle_io_reply({:error, {:put_chars, :unicode, _} = error}, state) do
    retry_log(error, state)
  end

  def handle_io_reply({:error, :put_chars}, %{output: output} = state) do
    retry_log({:put_chars, :unicode, output}, state)
  end

  def handle_io_reply({:error, error}, _) do
    raise "failure while logging console messages: " <> inspect(error)
  end

  defp retry_log(error, %{device: device, ref: ref, output: dirty} = state) do
    Process.demonitor(ref, [:flush])

    try do
      :unicode.characters_to_binary(dirty)
    rescue
      ArgumentError ->
        clean = ["failure while trying to log malformed data: ", inspect(dirty), ?\n]
        %{state | ref: async_io(device, clean), output: clean}
    else
      {_, good, bad} ->
        clean = [good | Logger.Formatter.prune(bad)]
        %{state | ref: async_io(device, clean), output: clean}

      _ ->
        # A well behaved IO device should not error on good data
        raise "failure while logging consoles messages: " <> inspect(error)
    end
  end

  def flush(%{ref: nil} = state), do: state

  def flush(state) do
    state
    |> await_io()
    |> flush()
  end
end
