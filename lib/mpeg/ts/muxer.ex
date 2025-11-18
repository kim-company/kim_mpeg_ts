defmodule MPEG.TS.Muxer do
  @moduledoc """
  Module responsible for muxing acces units into mpeg-ts packets.
  """

  alias MPEG.TS.{Packet, PAT, PES, PMT, PSI}
  alias MPEG.TS.Marshaler

  @default_program_id 0x1000
  @start_pid 0x100
  @pat_pid 0
  @pmt_pid 0x1000
  @max_counter 16
  @ts_payload_size 184

  @type t :: %__MODULE__{
          pat: PAT.t(),
          pat_version: pos_integer(),
          pmt: PMT.t(),
          pmt_version: pos_integer(),
          continuity_counters: %{required(Packet.pid_t()) => 0..15},
          pid_to_stream_id: %{required(Packet.pid_t()) => non_neg_integer()}
        }

  defstruct [:pat, :pat_version, :pmt, :pmt_version, :continuity_counters, :pid_to_stream_id]

  @doc """
  Create a new muxer.
  """
  @spec new() :: t()
  def new() do
    %__MODULE__{
      pat: %PAT{programs: %{1 => @default_program_id}},
      pat_version: 0,
      pmt: %PMT{},
      pmt_version: 0,
      continuity_counters: %{@pat_pid => 0, @pmt_pid => 0},
      pid_to_stream_id: %{}
    }
  end

  @doc """
  Add a new elementary stream.
  """
  @spec add_elementary_stream(t(), atom(), Keyword.t()) :: {Packet.pid_t(), t()}
  def add_elementary_stream(%__MODULE__{pmt: pmt} = muxer, stream_type, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        pcr?: false,
        program_info: [],
        pid: @start_pid + map_size(pmt.streams)
      )

    pid = opts[:pid]

    if Map.has_key?(pmt.streams, pid) do
      raise RuntimeError, "PID #{pid} is already present in PMT table"
    end

    stream_type_id = PMT.encode_stream_type(stream_type)
    stream_category = PMT.get_stream_category_by_id(stream_type_id)
    streams_by_type = Enum.count(pmt.streams, fn {_pid, s} -> s.stream_type == stream_type end)

    stream_id =
      case stream_category do
        :video -> 0xE0 + streams_by_type
        :audio -> 0xC0 + streams_by_type
        :subtitles -> 0xBD
        :cues -> 0xBD
        :data -> 0xBD
        :ipmp -> 0xF0 + streams_by_type
        :metadata -> 0xF0 + streams_by_type
        :other -> 0xBD
      end

    new_streams =
      Map.put(pmt.streams, pid, %{stream_type_id: stream_type_id, stream_type: stream_type})

    pmt = %PMT{
      pmt
      | streams: new_streams,
        pcr_pid: if(opts[:pcr?], do: pid, else: pmt.pcr_pid),
        program_info: pmt.program_info ++ opts[:program_info]
    }

    muxer = %__MODULE__{
      muxer
      | pmt: pmt,
        pmt_version: muxer.pmt_version + 1,
        continuity_counters: Map.put(muxer.continuity_counters, pid, 0),
        pid_to_stream_id: Map.put(muxer.pid_to_stream_id, pid, stream_id)
    }

    {pid, muxer}
  end

  @doc """
  Mux the PAT table into a packet.
  """
  @spec mux_pat(t()) :: {Packet.t(), t()}
  def mux_pat(muxer) do
    mux_psi(muxer, @pat_pid, %PSI{
      header: psi_extended_header(0x00, muxer.pat_version),
      table: muxer.pat
    })
  end

  @doc """
  Mux the PMT table into a packet.
  """
  @spec mux_pmt(t()) :: {Packet.t(), t()}
  def mux_pmt(muxer) do
    mux_psi(muxer, @pmt_pid, %PSI{
      header: psi_extended_header(0x02, muxer.pmt_version),
      table: muxer.pmt
    })
  end

  @doc """
  Mux a generic PSI into a packet.
  """
  @spec mux_psi(t(), Packet.pid_t(), MPEG.TS.PSI.t()) :: {Packet.t(), t()}
  def mux_psi(muxer, pid, psi) do
    continuity_counter = Map.fetch!(muxer.continuity_counters, pid)

    packet =
      psi
      |> Marshaler.marshal()
      |> Packet.new(
        pid: pid,
        pusi: true,
        continuity_counter: continuity_counter,
        random_access_indicator: false
      )

    continuity_counters = Map.update!(muxer.continuity_counters, pid, &rem(&1 + 1, @max_counter))
    {packet, %{muxer | continuity_counters: continuity_counters}}
  end

  @doc """
  Mux a PCR packet.
  """
  @spec mux_pcr(t(), MPEG.TS.timestamp_ns()) :: {Packet.t(), t()}
  def mux_pcr(muxer, pcr) do
    pcr_pid = muxer.pmt.pcr_pid
    continuity_counter = Map.fetch!(muxer.continuity_counters, pcr_pid)
    packet = Packet.new(<<>>, pid: pcr_pid, continuity_counter: continuity_counter, pcr: pcr)

    continuity_counters =
      Map.update!(muxer.continuity_counters, pcr_pid, &rem(&1 + 1, @max_counter))

    {packet, %{muxer | continuity_counters: continuity_counters}}
  end

  @doc """
  Mux a media sample.

  The following optional options may be provided:
    * `:sync?` - whether the sample is a sync sample (keyframe). Default: `false`
    * `:send_pcr?` - whether to send a PCR with this sample. Default: `false`
    * `:dts` - the decoding timestamp of the sample (in nanoseconds). Default: `nil`

  Timestamps are in nanoseconds.
  """
  @spec mux_sample(
          t(),
          Packet.pid_t(),
          iodata(),
          MPEG.TS.timestamp_ns(),
          keyword()
        ) ::
          {[Packet.t()], t()}
  def mux_sample(muxer, pid, payload, pts, opts \\ []) do
    continuity_counter = Map.fetch!(muxer.continuity_counters, pid)
    send_pcr? = Keyword.get(opts, :send_pcr?, false)

    pes = PES.new(payload, stream_id: muxer.pid_to_stream_id[pid], dts: opts[:dts], pts: pts)
    packets = chunk_pes(pes, pid, opts[:sync?] || false, send_pcr?, continuity_counter)

    continuity_counters =
      Map.update!(muxer.continuity_counters, pid, &rem(&1 + length(packets), @max_counter))

    {packets, %{muxer | continuity_counters: continuity_counters}}
  end

  defp chunk_pes(pes, pid, sync?, send_pcr?, continuity_counter) do
    pes_data = Marshaler.marshal(pes)
    header_size = 8
    # PCR should be in nanoseconds, same as PTS/DTS
    pcr = if send_pcr?, do: pes.dts || pes.pts

    {0, @ts_payload_size - header_size}
    |> chunk(byte_size(pes_data))
    |> Stream.with_index(continuity_counter)
    |> Enum.map(fn {{offset, size}, index} ->
      %Packet{
        payload: binary_part(pes_data, offset, size),
        pid: pid,
        continuity_counter: rem(index, @max_counter)
      }
    end)
    |> then(fn [first | rest] ->
      first = %{first | pusi: true, random_access_indicator: sync?, pcr: pcr}
      [first | rest]
    end)
  end

  defp chunk({offset, size}, remaining) when remaining <= size, do: [{offset, remaining}]

  defp chunk({offset, size}, remaining) do
    [{offset, size} | chunk({offset + size, @ts_payload_size}, remaining - size)]
  end

  defp psi_extended_header(table_id, version) do
    %{
      table_id: table_id,
      section_syntax_indicator: true,
      transport_stream_id: 1,
      version_number: version,
      current_next_indicator: true,
      section_number: 0,
      last_section_number: 0
    }
  end
end
