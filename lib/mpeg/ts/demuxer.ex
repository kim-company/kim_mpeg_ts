defmodule MPEG.TS.Demuxer do
  @moduledoc """
  Responsible for demultiplexing a stream of MPEG.TS.Packet into the elemetary
  streams listed in the stream's Program Map Table. Does not yet handle PAT.
  """
  alias MPEG.TS.Packet
  alias MPEG.TS.{PMT, PAT, PES, PSI}
  alias MPEG.TS.StreamAggregator

  # MPEG-TS 33-bit rollover period in nanoseconds
  @rollover_period_ns round(2 ** 33 * (10 ** 9 / 90000))
  @rollover_threshold div(@rollover_period_ns, 2)

  defmodule Error do
    defexception [:message]

    defp format_data(nil), do: "<N/A>"

    defp format_data(data) do
      data
      |> :binary.bin_to_list()
      |> Enum.take(4)
      |> :binary.list_to_bin()
      |> :binary.encode_hex()
    end

    @impl true
    def exception(%{reason: reason, data: data}) do
      message = "Unrecoverable parse error: #{inspect(reason)} (#{format_data(data)})"
      %__MODULE__{message: message}
    end
  end

  defmodule Container do
    alias MPEG.TS.{PES, PSI}

    @type payload_t :: PES.t() | PSI.t()
    @type t :: %__MODULE__{
            pid: MPEG.TS.Packet.pid_t(),
            t: MPEG.TS.timestamp_ns(),
            payload: payload_t
          }
    defstruct [:pid, :t, :payload]
  end

  require Logger

  @type t :: %__MODULE__{
          # When enabled, raises on invalid packets.
          strict?: boolean(),
          # If enabled, packets come out after the random access indicator has been found.
          wait_rai?: boolean(),
          pending: binary(),
          # Tracks the last dts value found. This is used to assign timing information to PSI
          # payloads, which might, or might not, carry it within their payloads.
          last_dts: MPEG.TS.timestamp_ns(),
          # Each PID that requires ES re-assemblement get's a queue here,
          # from which we extrac complete buffers.
          stream_aggregators: %{Packet.pid_t() => StreamAggregator.t()},
          # Each stream that appears in any PMT is added here as they are the
          # streams that have been recognised. Each of these streams has its own
          # stream_aggregators, if needed (i.e. they'r category is either audio or video).
          streams: %{Packet.pid_t() => PMT.stream_t()},
          # Reverse map of the PAT table, used for fast lookup
          pids_with_pmt: %{Packet.pid_t() => PAT.program_id_t()},
          # Tracks timestamp rollover state per PID
          rollover: %{Packet.pid_t() => %{pts: map(), dts: map()}}
        }

  defstruct [
    :strict?,
    :wait_rai?,
    pending: <<>>,
    pids_with_pmt: %{},
    stream_aggregators: %{},
    streams: %{},
    last_dts: nil,
    rollover: %{}
  ]

  @spec new() :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, strict?: false, wait_rai?: true)
    %__MODULE__{strict?: opts[:strict?], wait_rai?: opts[:wait_rai?]}
  end

  def filter(units, pid) do
    units
    |> Stream.filter(fn x -> x.pid == pid end)
    |> Enum.map(fn x -> x.payload end)
  end

  def available_streams(state), do: state.streams

  def stream!(stream, opts \\ []) do
    Stream.transform(
      stream,
      fn -> new(opts) end,
      fn data, d -> demux(d, data) end,
      fn d -> flush(d) end,
      fn _ -> :ok end
    )
  end

  def stream_file!(path, opts \\ []) do
    path
    |> File.stream!(188, [:binary])
    |> stream!(opts)
  end

  @spec demux(t(), binary()) :: {[Container.t()], t()}
  def demux(state, data) do
    {packets, state} =
      get_and_update_in(state, [Access.key!(:pending)], fn pending ->
        try do
          parse_packets(pending <> data)
        rescue
          e in Error ->
            unless state.strict? do
              Logger.warning("Parse error: #{inspect(e.message)}")
              {[], state}
            else
              reraise e, __STACKTRACE__
            end
        end
      end)

    demux_packets(state, packets, [])
  end

  @spec flush(t()) :: {[Container.t()], t()}
  def flush(state) do
    state = put_in(state, [Access.key!(:pending)], <<>>)

    Enum.flat_map_reduce(state.stream_aggregators, state, fn {pid, aggregator}, acc_state ->
      {pes, aggregator} = flush_aggregator(aggregator, acc_state.strict?, pid, state)
      {containers, updated_state} = apply_rollover_correction(pes, pid, acc_state)

      updated_state =
        updated_state
        |> put_in([Access.key!(:stream_aggregators), pid], aggregator)
        |> update_last_dts_for_video(pid, containers)

      {containers, updated_state}
    end)
  end

  defp demux_packets(state, [], acc) do
    {Enum.reverse(acc), state}
  end

  defp demux_packets(state, [pkt | pkts], acc) when pkt.pid_class == :null_packet do
    # We're completely ignoring stuffing bytes.
    demux_packets(state, pkts, acc)
  end

  defp demux_packets(state, [pkt | pkts], acc)
       when is_map_key(state.stream_aggregators, pkt.pid) do
    # This is a PES packet.
    {pes, state} =
      get_and_update_in(state, [Access.key!(:stream_aggregators), pkt.pid], fn queue ->
        try do
          StreamAggregator.put_and_get(queue, pkt)
        rescue
          e in StreamAggregator.Error ->
            unless state.strict? do
              Logger.warning("PID #{pkt.pid} error: #{e.message}")
              {[], StreamAggregator.new(wait_rai?: state.wait_rai?)}
            else
              reraise e, __STACKTRACE__
            end
        end
      end)

    {containers, state} = apply_rollover_correction(pes, pkt.pid, state)
    state = update_last_dts_for_video(state, pkt.pid, containers)

    demux_packets(state, pkts, Enum.reverse(containers) ++ acc)
  end

  defp demux_packets(state, [pkt | pkts], acc)
       when pkt.pid_class in [:psi, :pat] or is_map_key(state.pids_with_pmt, pkt.pid) do
    with {:ok, psi} <- PSI.unmarshal(pkt.payload, pkt.pusi) do
      state =
        cond do
          is_map_key(state.pids_with_pmt, pkt.pid) and psi.table_type == :pmt ->
            handle_pmt(psi.table, state)

          pkt.pid_class == :pat and psi.table_type == :pat ->
            handle_pat(psi.table, state)

          true ->
            # We just forward the PSI packet as is.
            state
        end

      best_effort_t = state.last_dts
      pid_rollover = Map.get(state.rollover, pkt.pid, %{pts: %{}})

      {corrected_dts, updated_dts} = correct_timestamp(pkt.pid, best_effort_t, pid_rollover.pts)

      container = %Container{
        pid: pkt.pid,
        payload: psi,
        t: corrected_dts
      }

      state = put_in(state, [Access.key!(:rollover), pkt.pid], %{pts: updated_dts})

      demux_packets(state, pkts, [container | acc])
    else
      {:error, reason} ->
        if state.strict? do
          raise Error, %{reason: reason, data: pkt.payload}
        else
          Logger.warning("PID #{pkt.pid}: error: #{inspect(reason)}")
          demux_packets(state, pkts, acc)
        end
    end
  end

  defp demux_packets(state, [pkt | pkts], acc) do
    # This packet does not belong to any PES stream we know -- it might be
    # an unknown stream (we did not receive PMTs yet) or a PSI stream.
    Logger.warning("Unexpected packet received: #{inspect(pkt)}")
    demux_packets(state, pkts, acc)
  end

  defp handle_pat(pat, state) do
    state
    |> update_in([Access.key!(:pids_with_pmt)], fn old ->
      pat.programs
      |> Enum.map(fn {k, v} -> {v, k} end)
      |> Map.new()
      |> then(fn x -> Map.merge(old, x) end)
    end)
  end

  defp handle_pmt(pmt, state) do
    state
    |> update_in([Access.key!(:streams)], &Map.merge(&1, pmt.streams))
    |> then(fn state ->
      # Each stream that contains a PES stream should have its aggregator.
      state.streams
      |> Enum.filter(fn {_pid, stream} -> PMT.pes_stream?(stream) end)
      |> Enum.reduce(state, fn {pid, _stream}, state ->
        update_in(state, [Access.key!(:stream_aggregators), pid], fn
          nil -> StreamAggregator.new(wait_rai?: state.wait_rai?)
          queue -> queue
        end)
      end)
    end)
  end

  defp parse_packets(buffer) do
    {ok, err} =
      buffer
      |> Packet.parse_many()
      |> Enum.split_with(fn tuple -> elem(tuple, 0) == :ok end)

    # fail fast in case a critical error is encountered. If data becomes
    # mis-aligned this module should be responsible for fixing it.
    critical_err =
      Enum.find(err, fn
        {:error, :invalid_packet, _} -> true
        {:error, :invalid_data, _} -> true
        _ -> false
      end)

    if critical_err != nil do
      {:error, reason, data} = critical_err
      raise Error, %{reason: reason, data: data}
    end

    to_buffer =
      err
      |> Enum.filter(fn
        {:error, :not_enough_data, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {_, _, data} -> data end)
      |> Enum.reduce(<<>>, fn x, acc -> acc <> x end)

    ok = Enum.map(ok, fn {:ok, x} -> x end)

    {ok, to_buffer}
  end

  defp flush_aggregator(aggregator, strict?, pid, state) do
    try do
      StreamAggregator.flush(aggregator)
    rescue
      e in StreamAggregator.Error ->
        unless strict? do
          Logger.warning("PID #{pid} error: #{e.message}")
          {[], StreamAggregator.new(wait_rai?: state.wait_rai?)}
        else
          reraise e, __STACKTRACE__
        end
    end
  end

  defp apply_rollover_correction(pes, pid, state) do
    Enum.map_reduce(pes, state, fn x, acc_state ->
      curr_rollover = Map.get(acc_state.rollover, pid, %{pts: %{}, dts: %{}})

      {corrected_pts, updated_pts} = correct_timestamp(pid, x.pts, curr_rollover.pts)
      {corrected_dts, updated_dts} = correct_timestamp(pid, x.dts, curr_rollover.dts)

      corrected_x = %{x | pts: corrected_pts, dts: corrected_dts}

      container = %Container{
        pid: pid,
        payload: corrected_x,
        t: corrected_dts || corrected_pts
      }

      updated_state =
        put_in(acc_state, [Access.key!(:rollover), pid], %{pts: updated_pts, dts: updated_dts})

      {container, updated_state}
    end)
  end

  defp update_last_dts_for_video(state, pid, containers) do
    case get_in(state, [Access.key(:streams, %{}), Access.key(pid, %{}), :stream_type]) do
      type when not is_nil(type) ->
        if PMT.get_stream_category(type) == :video and containers != [] do
          last_container = List.last(containers)
          last_dts = last_container.payload.dts || last_container.payload.pts
          put_in(state, [Access.key!(:last_dts)], last_dts)
        else
          state
        end

      _ ->
        state
    end
  end

  defp correct_timestamp(_pid, nil, ts_state) do
    {nil, ts_state}
  end

  defp correct_timestamp(pid, timestamp, ts_state) when ts_state != %{} do
    %{last: last_ts, count: count} = ts_state

    cond do
      last_ts - timestamp > @rollover_threshold ->
        new_count = count + 1
        corrected_ts = timestamp + new_count * @rollover_period_ns

        Logger.info(
          "MPEG.TS.Demuxer incrementing rollover count for #{pid} to #{new_count}. Corrected TS: #{corrected_ts}"
        )

        {corrected_ts, %{last: timestamp, count: new_count}}

      timestamp - last_ts > @rollover_threshold and count > 0 ->
        new_count = count - 1
        corrected_ts = timestamp + new_count * @rollover_period_ns

        Logger.info(
          "MPEG.TS.Demuxer decrementing rollover count for #{pid} to #{new_count}. Corrected TS: #{corrected_ts}"
        )

        {corrected_ts, %{last: timestamp, count: new_count}}

      true ->
        corrected_ts = timestamp + count * @rollover_period_ns
        {corrected_ts, %{last: timestamp, count: count}}
    end
  end

  defp correct_timestamp(_pid, timestamp, _ts_state) do
    {timestamp, %{last: timestamp, count: 0}}
  end
end
