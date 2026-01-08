defmodule MPEG.TS.DemuxerTest do
  use ExUnit.Case

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
