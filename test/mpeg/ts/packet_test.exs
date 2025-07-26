defmodule MPEG.TS.PacketTest do
  use ExUnit.Case

  alias MPEG.TS.{Marshaler, Packet}
  alias Support.Factory

  describe "MPEG TS Packet parser" do
    test "handles valid PAT packet" do
      raw_data = Factory.pat_packet()
      assert {:ok, %Packet{payload: data}} = Packet.parse(raw_data)
      assert byte_size(data) > 0
    end

    test "handles valid PMT packet" do
      raw_data = Factory.pmt_packet()
      assert {:ok, %Packet{payload: data}} = Packet.parse(raw_data)
      assert byte_size(data) > 0
    end

    test "asks for more data if packet is not complete but valid" do
      <<partial::160-binary, _rest::binary>> = Factory.pat_packet()
      assert {:error, :not_enough_data, _data} = Packet.parse(partial)
    end

    test "successfully parse a valid PartialPES packet" do
      raw_data = Factory.data_packet_video()
      assert byte_size(raw_data) == Packet.packet_size()
      assert {:ok, %Packet{payload: data}} = Packet.parse(raw_data)
      assert byte_size(data) > 0
    end

    test "fails when garbage is provided" do
      data = "garbagio"
      assert {:error, :invalid_data, ^data} = Packet.parse(data)
    end
  end

  describe "MPEG TS Packet marshaler" do
    test "Marshal a packet with only payload" do
      payload = :binary.copy(<<0x01>>, 184)
      expected_payload = <<0x47, 0x01, 0x00, 0x1F, payload::binary>>

      packet = Packet.new(payload, pid: 0x100, continuity_counter: 15)
      assert Marshaler.marshal(packet) == expected_payload

      assert {:ok,
              %Packet{
                payload: ^payload,
                continuity_counter: 15,
                pid: 0x100,
                pusi: false,
                random_access_indicator: false,
                scrambling: :no
              }} = Packet.parse(expected_payload)
    end

    test "Marshal a packet with payload and adaptation" do
      payload = :binary.copy(<<0x01>>, 176)

      expected_payload =
        <<0x47, 0x41, 0x00, 0x3A, 0x07, 0x50, 0x00, 0x00, 0x00, 0x01, 0xFE, 0x64,
          payload::binary>>

      packet =
        Packet.new(payload,
          pid: 0x100,
          continuity_counter: 10,
          random_access_indicator: true,
          pusi: true,
          pcr: 1000
        )

      assert Marshaler.marshal(packet) == expected_payload
    end

    test "Add stuffing bytes" do
      payload = :binary.copy(<<0x01>>, 10)

      expected_payload =
        <<0x47, 0x41, 0x00, 0x3A, 0xAD, 0x00>> <> :binary.copy(<<0xFF>>, 172) <> payload

      packet = Packet.new(payload, pid: 0x100, continuity_counter: 10, pusi: true)

      assert Marshaler.marshal(packet) == expected_payload
      assert {:ok, %Packet{payload: ^payload}} = Packet.parse(expected_payload)
    end
  end
end
