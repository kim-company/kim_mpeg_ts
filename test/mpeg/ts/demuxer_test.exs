defmodule MPEG.TS.DemuxerTest do
  use ExUnit.Case

  import ExUnit.CaptureLog
  alias MPEG.TS.Demuxer

  @broken "test/data/broken.ts"
  @avsync "test/data/avsync.ts"
  # NOTE: This test file was generated using the following ffmpeg command:
  # ```bash
  # ffmpeg -f lavfi -i "testsrc2=size=128x72:rate=1" -t 20 \
  #    -c:v libx264 -preset veryslow -crf 42 -pix_fmt yuv420p \
  #    -g 30 -bf 3 -sc_threshold 0 -x264-params "keyint=30:min-keyint=30:scenecut=0" \
  #    -an \
  #    -mpegts_copyts 1 \
  #    -output_ts_offset 95433.7176889 \
  #    -pat_period 1.0 -sdt_period 5.0 \
  #    -f mpegts rollover.ts
  # ```
  @rollover "test/data/rollover.ts"

  defp demux_file!(path, opts \\ []) do
    path
    |> Demuxer.stream_file!(opts)
    |> Enum.into([])
  end

  test "finds PMT table" do
    units = demux_file!(@avsync)

    container =
      Enum.find(units, fn
        %{payload: %MPEG.TS.PSI{table_type: :pmt}} -> true
        _ -> false
      end)

    assert %MPEG.TS.PMT{
             pcr_pid: 256,
             program_info: [],
             streams: %{
               256 => %{stream_type: :H264_AVC, stream_type_id: 27, descriptors: []},
               257 => %{stream_type: :AAC_ADTS, stream_type_id: 15, descriptors: []}
             }
           } == container.payload.table
  end

  test "demuxes PES stream" do
    units = demux_file!(@avsync)

    count =
      units
      |> Enum.filter(fn %{payload: %mod{}} -> mod == MPEG.TS.PES end)
      |> length()

    assert count > 0
  end

  test "drops packets until PAT and PMT are available" do
    muxer = MPEG.TS.Muxer.new()
    {pid, muxer} = MPEG.TS.Muxer.add_elementary_stream(muxer, :H264_AVC, pid: 0x100)
    {pat, muxer} = MPEG.TS.Muxer.mux_pat(muxer)
    {pmt, muxer} = MPEG.TS.Muxer.mux_pmt(muxer)

    pre_payload = :binary.copy(<<1>>, 200)
    post_payload = :binary.copy(<<2>>, 200)

    {pre_packets, muxer} = MPEG.TS.Muxer.mux_sample(muxer, pid, pre_payload, 0, sync?: true)

    {post_packets, _muxer} =
      MPEG.TS.Muxer.mux_sample(muxer, pid, post_payload, 9_000, sync?: true)

    packets = [hd(pre_packets), pat, pmt] ++ post_packets

    units =
      packets
      |> MPEG.TS.Marshaler.marshal()
      |> Stream.map(&IO.iodata_to_binary/1)
      |> Demuxer.stream!(strict?: true)
      |> Enum.into([])

    pes = Demuxer.filter(units, pid)

    assert length(pes) == 1
    assert %MPEG.TS.PES{data: ^post_payload} = List.first(pes)
  end

  test "recovers when the stream starts in the middle of a PES" do
    muxer = MPEG.TS.Muxer.new()
    {pid, muxer} = MPEG.TS.Muxer.add_elementary_stream(muxer, :H264_AVC, pid: 0x100)
    {pat, muxer} = MPEG.TS.Muxer.mux_pat(muxer)
    {pmt, muxer} = MPEG.TS.Muxer.mux_pmt(muxer)

    pre_payload = :binary.copy(<<1>>, 800)
    post_payload = :binary.copy(<<2>>, 800)

    {pre_packets, muxer} = MPEG.TS.Muxer.mux_sample(muxer, pid, pre_payload, 0, sync?: true)

    {post_packets, _muxer} =
      MPEG.TS.Muxer.mux_sample(muxer, pid, post_payload, 9_000, sync?: true)

    # Drop the first PES-start packet to emulate attaching to a stream mid-PES.
    packets = [pat, pmt] ++ tl(pre_packets) ++ post_packets

    units =
      packets
      |> MPEG.TS.Marshaler.marshal()
      |> Stream.map(&IO.iodata_to_binary/1)
      |> Demuxer.stream!(strict?: true, wait_rai?: false)
      |> Enum.into([])

    pes = Demuxer.filter(units, pid)

    assert length(pes) == 1
    assert %MPEG.TS.PES{data: ^post_payload} = List.first(pes)
  end

  test "in non-strict mode, drops incomplete PES and keeps next one" do
    muxer = MPEG.TS.Muxer.new()
    {pid, muxer} = MPEG.TS.Muxer.add_elementary_stream(muxer, :H264_AVC, pid: 0x100)
    {pat, muxer} = MPEG.TS.Muxer.mux_pat(muxer)
    {pmt, muxer} = MPEG.TS.Muxer.mux_pmt(muxer)

    pre_payload = :binary.copy(<<1>>, 800)
    post_payload = :binary.copy(<<2>>, 800)

    {pre_packets, muxer} = MPEG.TS.Muxer.mux_sample(muxer, pid, pre_payload, 0, sync?: true)

    {post_packets, _muxer} =
      MPEG.TS.Muxer.mux_sample(muxer, pid, post_payload, 9_000, sync?: true)

    # Corrupt the first PES by dropping one continuation packet in the middle.
    packets = [pat, pmt] ++ List.delete_at(pre_packets, 2) ++ post_packets

    units =
      packets
      |> MPEG.TS.Marshaler.marshal()
      |> Stream.map(&IO.iodata_to_binary/1)
      |> Demuxer.stream!(strict?: false, wait_rai?: false)
      |> Enum.into([])

    pes = Demuxer.filter(units, pid)

    assert length(pes) == 1
    assert %MPEG.TS.PES{data: ^post_payload} = List.first(pes)
  end

  test "in strict mode, raises on incomplete PES" do
    muxer = MPEG.TS.Muxer.new()
    {pid, muxer} = MPEG.TS.Muxer.add_elementary_stream(muxer, :H264_AVC, pid: 0x100)
    {pat, muxer} = MPEG.TS.Muxer.mux_pat(muxer)
    {pmt, muxer} = MPEG.TS.Muxer.mux_pmt(muxer)

    pre_payload = :binary.copy(<<1>>, 800)
    post_payload = :binary.copy(<<2>>, 800)

    {pre_packets, muxer} = MPEG.TS.Muxer.mux_sample(muxer, pid, pre_payload, 0, sync?: true)

    {post_packets, _muxer} =
      MPEG.TS.Muxer.mux_sample(muxer, pid, post_payload, 9_000, sync?: true)

    packets = [pat, pmt] ++ List.delete_at(pre_packets, 2) ++ post_packets

    assert_raise MPEG.TS.StreamAggregator.Error, fn ->
      packets
      |> MPEG.TS.Marshaler.marshal()
      |> Stream.map(&IO.iodata_to_binary/1)
      |> Demuxer.stream!(strict?: true, wait_rai?: false)
      |> Enum.into([])
    end
  end

  test "works with partial data" do
    one_shot = demux_file!(@avsync)

    chunked =
      @avsync
      |> File.open!([:binary])
      |> IO.binstream(512)
      |> Demuxer.stream!()
      |> Enum.into([])

    assert length(one_shot) > 0
    assert length(chunked) == length(List.flatten(one_shot))

    chunked
    |> Enum.zip(one_shot)
    |> Enum.with_index()
    |> Enum.each(fn {{left, right}, index} ->
      assert left == right,
             "packet #{index}/#{length(chunked) - 1}:\n\tone_shot=#{inspect(right, binaries: :as_strings)}\n\tchunked=#{inspect(left, binaries: :as_strings)}"
    end)
  end

  test "raises on corrupted packets" do
    assert_raise MPEG.TS.StreamAggregator.Error, fn ->
      _ = demux_file!(@broken, strict?: true)
    end
  end

  test "non-strict demux recovers when a parse error happens on the first feed" do
    # Regression: in non-strict mode, when parse_packets raises (e.g. the
    # stream attaches mid-packet so the first 188-byte chunk is not
    # 0x47-aligned), the rescue branch used to stash the whole demuxer
    # struct into :pending. The next feed then did `pending <> data`,
    # crashing with an ArgumentError during binary construction.
    muxer = MPEG.TS.Muxer.new()
    {pid, muxer} = MPEG.TS.Muxer.add_elementary_stream(muxer, :H264_AVC, pid: 0x100)
    {pat, muxer} = MPEG.TS.Muxer.mux_pat(muxer)
    {pmt, muxer} = MPEG.TS.Muxer.mux_pmt(muxer)
    payload = :binary.copy(<<0xAB>>, 800)
    {packets, _muxer} = MPEG.TS.Muxer.mux_sample(muxer, pid, payload, 0, sync?: true)

    valid =
      [pat, pmt | packets]
      |> MPEG.TS.Marshaler.marshal()
      |> Enum.map(&IO.iodata_to_binary/1)
      |> Enum.join()

    # 188 non-sync bytes -> parse_many returns {:error, :invalid_data, _}
    # -> parse_packets raises MPEG.TS.Demuxer.Error.
    garbage = :binary.copy(<<0x00>>, 188)

    demuxer = Demuxer.new(wait_rai?: false)
    {[], demuxer} = Demuxer.demux(demuxer, garbage)
    assert is_binary(demuxer.pending)

    {units1, demuxer} = Demuxer.demux(demuxer, valid)
    {units2, _demuxer} = Demuxer.flush(demuxer)
    units = units1 ++ units2
    assert Enum.any?(units, &match?(%{payload: %MPEG.TS.PES{data: ^payload}}, &1))
  end

  test "ignores undeclared :psi-classified PIDs without warning per packet" do
    # Regression: PIDs in 0x0020..0x1FFA are classified as :psi by Packet,
    # but only PIDs the PAT lists as PMT-carrying actually carry PSI. The
    # demuxer used to attempt PSI parsing for any :psi-classified PID and
    # log a warning per packet when the header didn't unmarshal. Streams
    # carrying an undeclared PID (e.g. video the consumer doesn't care
    # about) would flood the log. These packets should be dropped quietly.
    muxer = MPEG.TS.Muxer.new()
    {audio_pid, muxer} = MPEG.TS.Muxer.add_elementary_stream(muxer, :AAC_ADTS, pid: 0x201)
    {pat, muxer} = MPEG.TS.Muxer.mux_pat(muxer)
    {pmt, muxer} = MPEG.TS.Muxer.mux_pmt(muxer)
    payload = :binary.copy(<<0x42>>, 800)
    {audio_packets, _muxer} = MPEG.TS.Muxer.mux_sample(muxer, audio_pid, payload, 0, sync?: true)

    undeclared =
      Enum.map(0..7, fn cc ->
        MPEG.TS.Packet.new(:binary.copy(<<0xCC>>, 184),
          pid: 0x101,
          pid_class: :psi,
          pusi: true,
          continuity_counter: cc
        )
      end)

    binary =
      ([pat, pmt] ++ undeclared ++ audio_packets)
      |> MPEG.TS.Marshaler.marshal()
      |> Enum.map(&IO.iodata_to_binary/1)
      |> Enum.join()

    {{units, _}, log} =
      with_log(fn ->
        demuxer = Demuxer.new(wait_rai?: false)
        {u1, demuxer} = Demuxer.demux(demuxer, binary)
        {u2, demuxer} = Demuxer.flush(demuxer)
        {u1 ++ u2, demuxer}
      end)

    refute log =~ "PID 257"
    refute log =~ "Unexpected packet"
    assert Enum.any?(units, &match?(%{payload: %MPEG.TS.PES{data: ^payload}}, &1))
  end

  test "correctly handles the mpegts rollover and converts it into monotonic pts/dts" do
    rollover_period_ns = round(2 ** 33 * (10 ** 9 / 90000))

    units = demux_file!(@rollover)

    # Filter for PID 0x100 (256) which contains the H264 video stream
    pes_units =
      units
      |> Enum.filter(fn
        %{pid: 256, payload: %MPEG.TS.PES{}} -> true
        _ -> false
      end)

    assert length(pes_units) > 0, "Expected to find PES units for PID 256"

    # Verify timestamps are monotonically increasing and within expected bounds
    pes_units
    |> Enum.reduce(fn container, prev_container ->
      pes = container.payload

      # Assert that the timestamps are monotonically increasing
      prev_pes = prev_container.payload
      assert pes.dts > prev_pes.dts, "DTS should be monotonically increasing"

      # Ensure that its a consistent timeline (within reasonable deltas)
      assert_in_delta(pes.dts, prev_pes.dts, 1_000_000_000)
      assert_in_delta(pes.pts, prev_pes.pts, 5_000_000_000)

      # Ensure that we don't go above the rollover period (plus some margin)
      assert pes.dts < rollover_period_ns + 60_000_000_000,
             "DTS should not exceed rollover period + 1 minute"

      assert pes.pts < rollover_period_ns + 60_000_000_000,
             "PTS should not exceed rollover period + 1 minute"

      container
    end)
  end
end
