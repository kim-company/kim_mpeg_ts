defmodule MPEG.TS.PESTest do
  use ExUnit.Case, async: true

  alias MPEG.TS.{Marshaler, PartialPES, PES}

  @payload <<0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8, 0x9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF>>
  @pes_payload <<0, 0, 1, 224, 0, 28, 132, 192, 10, 49, 0, 1, 14, 17, 17, 0, 1, 7, 9,
                 @payload::binary>>

  describe "marshal a PES packet" do
    test "marshal a PES packet" do
      pes = PES.new(@payload, stream_id: 224, dts: 900, pts: 1800)
      assert Marshaler.marshal(pes) == @pes_payload

      assert {:ok, %PartialPES{data: @payload, stream_id: 224, dts: 10_000_000, pts: 20_000_000}} =
               PartialPES.unmarshal(@pes_payload, true)
    end

    test "marshal a PES with only pts" do
      pes_payload = PES.new(@payload, stream_id: 224, pts: 1800) |> Marshaler.marshal()

      assert {:ok, %PartialPES{data: @payload, stream_id: 224, dts: 20_000_000, pts: 20_000_000}} =
               PartialPES.unmarshal(pes_payload, true)
    end

    test "marshal a PES without pts and dts" do
      pes_payload = PES.new(@payload, stream_id: 224) |> Marshaler.marshal()

      assert {:ok, %PartialPES{data: @payload, stream_id: 224, dts: nil, pts: nil}} =
               PartialPES.unmarshal(pes_payload, true)
    end
  end
end
