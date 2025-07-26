defmodule MPEG.TS.PES do
  @type t :: %__MODULE__{
          data: binary(),
          stream_id: 0..255,
          pts: non_neg_integer() | nil,
          dts: non_neg_integer() | nil,
          is_aligned: boolean(),
          discontinuity: boolean()
        }

  @derive {Inspect, only: [:stream_id, :pts, :dts, :is_aligned, :discontinuity]}
  defstruct [:data, :stream_id, :pts, :dts, :is_aligned, discontinuity: false]

  @spec new(binary(), keyword()) :: t()
  def new(data, opts) do
    struct!(%__MODULE__{data: data}, opts)
  end

  defimpl MPEG.TS.Marshaler do
    alias MPEG.TS.PartialPES
    @max_pes_size 0xFFFF

    def marshal(pes) do
      optional_header =
        case PartialPES.has_header?(pes.stream_id) do
          true ->
            pts_dts = marshal_pts_dts(pes)

            <<_marker_bits = 0b10::2, _scrambling_control = 0::2, _priority = 0::1,
              _data_alignment = 1::1, _copyright = 0::1, _original = 0::1,
              pts_dts_indicator(pes)::2, 0::6, byte_size(pts_dts)::8, pts_dts::binary>>

          false ->
            <<>>
        end

      size = byte_size(pes.data) + byte_size(optional_header)
      size = if size > @max_pes_size, do: 0, else: size

      <<1::24, pes.stream_id, size::16, optional_header::binary, pes.data::binary>>
    end

    defp pts_dts_indicator(%{dts: nil, pts: nil}), do: 0
    defp pts_dts_indicator(%{dts: nil}), do: 2
    defp pts_dts_indicator(_pes), do: 3

    defp marshal_pts_dts(%{dts: nil, pts: nil}), do: <<>>
    defp marshal_pts_dts(%{dts: nil, pts: pts}), do: marshal_timestamp(0b0010, pts)

    defp marshal_pts_dts(%{dts: dts, pts: pts}) do
      marshal_timestamp(0b0011, pts) <> marshal_timestamp(0b0001, dts)
    end

    defp marshal_timestamp(prefix, timestamp) do
      chunk1 = Bitwise.bsr(timestamp, 30)
      chunk2 = Bitwise.bsr(timestamp, 15) |> Bitwise.band(0x7FFF)
      chunk3 = Bitwise.band(timestamp, 0x7FFF)

      <<prefix::4, chunk1::3, 0b1::1, chunk2::15, 0b1::1, chunk3::15, 0b1::1>>
    end
  end
end
