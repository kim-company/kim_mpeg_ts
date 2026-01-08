defmodule MPEG.TS.MuxerTest do
  use ExUnit.Case, async: true

  alias MPEG.TS.{Demuxer, Marshaler, Muxer, Packet, PAT, PMT, PSI, PES}

  setup do
    {:ok, muxer: Muxer.new()}
  end

  test "Mux PAT table", %{muxer: muxer} do
    {%Packet{pid: 0, pusi: true, continuity_counter: 0, payload: raw_psi}, _muxer} =
      Muxer.mux_pat(muxer)

    assert {:ok, %PSI{table: %PAT{programs: %{1 => 0x1000}}}} = PSI.unmarshal(raw_psi, true)
  end

  test "Mux PMT table", %{muxer: muxer} do
    {%Packet{pid: 0x1000, pusi: true, continuity_counter: 0, payload: raw_psi}, muxer} =
      Muxer.mux_pmt(muxer)

    assert {:ok, %PSI{table: %PMT{pcr_pid: 0x1FFF, program_info: [], streams: %{}}}} =
             PSI.unmarshal(raw_psi, true)

    {pid1, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)
    {pid2, muxer} = Muxer.add_elementary_stream(muxer, :AAC_ADTS)

    assert pid1 == 0x100
    assert pid2 == 0x101

    {%Packet{pid: 0x1000, pusi: true, continuity_counter: 1, payload: raw_psi}, _muxer} =
      Muxer.mux_pmt(muxer)

    assert {:ok,
            %PSI{
              table: %PMT{
                pcr_pid: 0x100,
                program_info: [],
                streams: %{
                  0x100 => %{stream_type: :H264_AVC, stream_type_id: 27, descriptors: []},
                  0x101 => %{stream_type: :AAC_ADTS, stream_type_id: 15, descriptors: []}
                }
              }
            }} = PSI.unmarshal(raw_psi, true)
  end

  test "Mux PMT table with descriptors", %{muxer: muxer} do
    descriptors = [%{tag: 0x59, data: <<0xAA>>}]

    {pid, muxer} =
      Muxer.add_elementary_stream(muxer, :PES_PRIVATE_DATA, descriptors: descriptors)

    {%Packet{pid: 0x1000, pusi: true, payload: raw_psi}, _muxer} = Muxer.mux_pmt(muxer)

    assert {:ok,
            %PSI{
              table: %PMT{
                streams: %{
                  ^pid => %{stream_type: :PES_PRIVATE_DATA, descriptors: ^descriptors}
                }
              }
            }} = PSI.unmarshal(raw_psi, true)
  end

  test "Mux PCR", %{muxer: muxer} do
    {pid, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)
    {%Packet{payload: <<>>, pcr: 100, pid: ^pid}, _muxer} = Muxer.mux_pcr(muxer, 100)
  end

  test "Mux sample", %{muxer: muxer} do
    {pid, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)

    sample_payload = :binary.copy(<<1>>, 1000)
    pts = 90000
    dts = 90000

    {packets, _muxer} = Muxer.mux_sample(muxer, pid, sample_payload, pts, dts: dts, sync?: true)

    assert length(packets) == 6
    assert %Packet{pusi: true, random_access_indicator: true, pid: ^pid} = hd(packets)

    for packet <- tl(packets) do
      assert packet.pid == pid
      refute packet.pusi
      refute packet.random_access_indicator
    end

    for {packet, idx} <- Enum.with_index(packets, 0) do
      assert packet.continuity_counter == rem(idx, 16)
    end
  end

  test "mux SCTE35", %{muxer: muxer} do
    {pid, muxer} =
      Muxer.add_elementary_stream(muxer, :SCTE_35_SPLICE,
        program_info: [%{tag: 5, data: "CUEI"}],
        pid: 500
      )

    table = Support.Factory.scte35()

    psi = %MPEG.TS.PSI{
      header: %{
        table_id: 0xFC,
        section_syntax_indicator: false
      },
      table: table
    }

    {packet, muxer} = Muxer.mux_psi(muxer, pid, psi)

    assert muxer.pmt == %MPEG.TS.PMT{
             pcr_pid: nil,
             program_info: [%{data: "CUEI", tag: 5}],
          streams: %{500 => %{stream_type: :SCTE_35_SPLICE, stream_type_id: 134, descriptors: []}}
           }

    assert packet.payload != ""
  end

  test "Mux and demux", %{muxer: muxer} do
    {video_pid, muxer} =
      Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)

    {audio_pid, muxer} = Muxer.add_elementary_stream(muxer, :AAC_ADTS)

    {pat, muxer} = Muxer.mux_pat(muxer)
    {pmt, muxer} = Muxer.mux_pmt(muxer)

    video_sample = :binary.copy(<<1>>, 1000)
    audio_sample = :binary.copy(<<2>>, 500)

    {video_packets, muxer} =
      Muxer.mux_sample(muxer, video_pid, video_sample, 0, sync?: true, send_pcr?: true)

    {audio_packets, muxer} = Muxer.mux_sample(muxer, audio_pid, audio_sample, 0, sync?: true)

    packets = [pat, pmt] ++ video_packets ++ audio_packets
    {video_packets, muxer} = Muxer.mux_sample(muxer, video_pid, video_sample, 18000)
    {audio_packets, _muxer} = Muxer.mux_sample(muxer, audio_pid, audio_sample, 9000, sync?: true)

    packets = packets ++ video_packets ++ audio_packets
    data = Marshaler.marshal(packets)

    units =
      data
      |> Stream.map(fn x -> IO.iodata_to_binary(x) end)
      |> Demuxer.stream!(strict?: true)
      |> Enum.into([])

    pmt =
      units
      |> Demuxer.filter(4096)
      |> List.first()

    assert %PMT{
             pcr_pid: ^video_pid,
             program_info: [],
            streams: %{
              ^video_pid => %{stream_type: :H264_AVC, stream_type_id: 27, descriptors: []},
              ^audio_pid => %{stream_type: :AAC_ADTS, stream_type_id: 15, descriptors: []}
            }
           } = pmt.table

    assert [video_sample1, video_sample2] = Demuxer.filter(units, video_pid)
    assert [audio_sample1, audio_sample2] = Demuxer.filter(units, audio_pid)

    for sample <- [video_sample1, video_sample2] do
      assert sample.data == video_sample
      assert sample.pts == sample.dts
      assert sample.stream_id == 0xE0
    end

    for sample <- [audio_sample1, audio_sample2] do
      assert sample.data == audio_sample
      assert sample.pts == sample.dts
      assert sample.stream_id == 0xC0
    end
  end

  test "Mux and demux PES private data JSON", %{muxer: muxer} do
    descriptors = [%{tag: 0x05, data: "JSON"}]
    {pid, muxer} = Muxer.add_elementary_stream(muxer, :PES_PRIVATE_DATA, descriptors: descriptors)
    {pat, muxer} = Muxer.mux_pat(muxer)
    {pmt, muxer} = Muxer.mux_pmt(muxer)

    json_payload = ~s({"type":"json","value":1})
    {packets, _muxer} = Muxer.mux_sample(muxer, pid, json_payload, 0, sync?: true)

    data = Marshaler.marshal([pat, pmt | packets])

    units =
      data
      |> Stream.map(&IO.iodata_to_binary/1)
      |> Demuxer.stream!(strict?: true)
      |> Enum.into([])

    assert %MPEG.TS.PSI{table: %PMT{streams: %{^pid => %{descriptors: ^descriptors}}}} =
             units |> Demuxer.filter(0x1000) |> List.first()

    assert %PES{data: ^json_payload} = Demuxer.filter(units, pid) |> List.first()
  end

  @tag :tmp_dir
  test "muxer correctly handles timestamp rollover conversion", %{tmp_dir: tmp_dir} do
    output_path = Path.join(tmp_dir, "rollover_muxed.ts")

    # Get original timestamps from input file
    original_containers =
      "test/data/rollover.ts"
      |> Demuxer.stream_file!()
      |> Stream.filter(fn
        %{pid: 0x100, payload: %PES{}} -> true
        _ -> false
      end)
      |> Enum.to_list()

    assert length(original_containers) > 0

    # Initialize muxer and setup streams
    muxer = Muxer.new()
    {video_pid, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)
    assert video_pid == 0x100

    # Mux PAT and PMT tables
    {pat, muxer} = Muxer.mux_pat(muxer)
    {pmt, muxer} = Muxer.mux_pmt(muxer)

    # Process all containers and mux them
    {packets, _muxer} =
      original_containers
      |> Enum.with_index()
      |> Enum.reduce({[pat, pmt], muxer}, fn {container, idx}, {acc_packets, acc_muxer} ->
        pes = container.payload

        # Mark first frame as sync point
        is_sync = idx == 0

        {new_packets, new_muxer} =
          Muxer.mux_sample(
            acc_muxer,
            video_pid,
            pes.data,
            pes.pts,
            dts: pes.dts,
            sync?: is_sync,
            send_pcr?: true
          )

        {acc_packets ++ new_packets, new_muxer}
      end)

    # Write muxed packets to file
    data = Marshaler.marshal(packets)
    binary_data = data |> Enum.map(&IO.iodata_to_binary/1) |> IO.iodata_to_binary()
    File.write!(output_path, binary_data)

    # Get timestamps from muxed output file
    output_containers =
      output_path
      |> Demuxer.stream_file!()
      |> Stream.filter(fn
        %{pid: 0x100, payload: %PES{}} -> true
        _ -> false
      end)
      |> Enum.to_list()

    assert length(output_containers) > 0
    assert length(original_containers) == length(output_containers)

    # Verify that original and output timestamps match exactly
    Enum.zip(original_containers, output_containers)
    |> Enum.each(fn {original, output} ->
      assert original.payload.pts == output.payload.pts,
             "PTS mismatch: original=#{original.payload.pts}, output=#{output.payload.pts}"

      assert original.payload.dts == output.payload.dts,
             "DTS mismatch: original=#{original.payload.dts}, output=#{output.payload.dts}"

      assert original.t == output.t,
             "Container timestamp mismatch: original=#{original.t}, output=#{output.t}"
    end)
  end
end
