defmodule GenLoggerBackend do
  alias GenLoggerBackend.Console

  @behaviour :gen_event

  defstruct buffer: [],
            buffer_size: 0,
            colors: nil,
            device: nil,
            format: nil,
            level: nil,
            max_buffer: nil,
            metadata: nil,
            output: nil,
            ref: nil

  @impl true
  def init(backend_name) when is_atom(backend_name) do
    config = Application.get_env(:logger, backend_name)
    config = Keyword.put_new_lazy(config, :backend_name, fn -> backend_name end)

    # special
    device = Keyword.get(config, :device, :user)

    if Process.whereis(device) do
      {:ok, Console.init(config, %__MODULE__{})}
    else
      {:error, :ignore}
    end
  end

  def init({__MODULE__, opts}) when is_list(opts) do
    backend_name = opts[:backend_name]
    config = configure_merge(Application.get_env(:logger, backend_name), opts)
    {:ok, Console.init(config, %__MODULE__{})}
  end

  @impl true
  def handle_call({:configure, options}, state) do
    backend_name = state[:backend_name]
    config = configure_merge(Application.get_env(:logger, backend_name), options)
    Application.put_env(:logger, backend_name, config)
    {:ok, :ok, Console.init(config, state)}
  end

  @impl true
  def handle_event({level, _gl, {Logger, msg, ts, md}}, state) do
    if meet_level?(level, state.level) do
      Console.handle_event(level, msg, ts, md, state)
    else
      {:ok, state}
    end
  end

  # special?
  def handle_event(:flush, state) do
    {:ok, Console.flush(state)}
  end

  def handle_event(_, state) do
    {:ok, state}
  end

  @impl true
  # special?
  def handle_info({:io_reply, ref, msg}, %{ref: ref} = state) do
    {:ok, Console.handle_io_reply(msg, state)}
  end

  def handle_info({:DOWN, ref, _, pid, reason}, %{ref: ref}) do
    raise "device #{inspect(pid)} exited: " <> Exception.format_exit(reason)
  end

  def handle_info(_, state) do
    {:ok, state}
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  defp meet_level?(_lvl, nil), do: true

  defp meet_level?(lvl, min) do
    Logger.compare_levels(lvl, min) != :lt
  end

  def configure_merge(env, options) do
    Keyword.merge(env, options, fn
      :colors, v1, v2 -> Keyword.merge(v1, v2)
      _, _v1, v2 -> v2
    end)
  end
end
