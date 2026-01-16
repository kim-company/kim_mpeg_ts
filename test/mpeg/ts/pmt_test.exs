defmodule MPEG.TS.PMTTest do
  use ExUnit.Case
  doctest MPEG.TS.PMT, import: true

  alias MPEG.TS.{Marshaler, PMT}
  alias MPEG.TS.PMT
  alias Support.Factory

  # TODO: add more exhaustive tests
  describe "Program Map Table table unmarshaler" do
    test "parses valid program map table with stream info but without program info" do
      assert {:ok, table} = PMT.unmarshal(Factory.pmt(), true)

      assert %PMT{
               pcr_pid: 0x0100,
               program_info: [],
               streams: %{
                 256 => %{stream_type: :H264_AVC, stream_type_id: 0x1B, descriptors: []},
                 257 => %{stream_type: :MPEG1_AUDIO, stream_type_id: 0x03, descriptors: []}
               }
             } = table
    end

    test "returns an error when map table is malformed" do
      valid_pmt = Factory.pmt()
      garbage_size = byte_size(valid_pmt) - 3
      <<garbage::binary-size(garbage_size), _::binary>> = valid_pmt
      assert {:error, :invalid_data} = PMT.unmarshal(garbage, true)
    end
  end

  describe "PMT marshaler" do
    test "marshal a PMT" do
      pmt = %PMT{
        pcr_pid: 0x0100,
        program_info: [],
        streams: %{
          256 => %{stream_type: :H264_AVC, stream_type_id: 0x1B, descriptors: []},
          257 => %{stream_type: :MPEG1_AUDIO, stream_type_id: 0x03, descriptors: []}
        }
      }

      assert Marshaler.marshal(pmt) == Factory.pmt()
    end
  end

  describe "PES stream type identification" do
    test "marks PES-bearing types as PES" do
      assert PMT.pes_stream_type?(:H264_AVC)
      assert PMT.pes_stream_type?(:PES_PRIVATE_DATA)
      assert PMT.pes_stream_type?(:PGS_SUBTITLE)
      assert PMT.pes_stream_type?({:USER_PRIVATE, 0xBC})
    end

    test "marks section-based types as non-PES" do
      refute PMT.pes_stream_type?(:PRIVATE_SECTIONS)
      refute PMT.pes_stream_type?(:MHEG)
      refute PMT.pes_stream_type?(:DSM_CC)
      refute PMT.pes_stream_type?(:ISO_13818_6_TYPE_A)
      refute PMT.pes_stream_type?(:ISO_14496_1_SL_IN_SECTIONS)
      refute PMT.pes_stream_type?(:METADATA_IN_SECTIONS)
      refute PMT.pes_stream_type?(:SCTE_35_SPLICE)
    end
  end

  describe "descriptor parsing" do
    test "parses ES descriptors and keeps PES classification" do
      pmt =
        <<0xE1, 0x00, 0xF0, 0x00, 0x06, 0xE1, 0x01, 0xF0, 0x03, 0x59, 0x01, 0xAA>>

      assert {:ok, %PMT{streams: %{257 => stream}}} = PMT.unmarshal(pmt, true)
      assert stream.descriptors == [%{tag: 0x59, data: <<0xAA>>}]
      assert PMT.pes_stream?(stream)
    end

    test "reclassifies Opus in PES private data via registration descriptor" do
      pmt =
        <<0xE1, 0x00, 0xF0, 0x00, 0x06, 0xE1, 0x01, 0xF0, 0x06, 0x05, 0x04, "Opus">>

      assert {:ok, %PMT{streams: %{257 => stream}}} = PMT.unmarshal(pmt, true)
      assert stream.descriptors == [%{tag: 0x05, data: "Opus"}]
      assert stream.stream_type == :OPUS
      assert PMT.pes_stream?(stream)
    end
  end
end
