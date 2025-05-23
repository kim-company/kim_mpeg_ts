defmodule MPEG.TS.PartialPES do
  @behaviour MPEG.TS.Unmarshaler

  @ts_clock_hz 90_000

  @moduledoc """
  Partial Packetized Elemetary Stream. PES packets are much larger in size than
  TS packets are. This means that they have to be unmarshaled from a series of
  payloads, hence each packet here will only contain a partial PES packet.
  """
  @type t :: %__MODULE__{
          data: binary(),
          stream_id: pos_integer(),
          pts: pos_integer(),
          dts: pos_integer(),
          is_aligned: boolean(),
          length: pos_integer(),
          discontinuity: boolean()
        }
  defstruct [:data, :stream_id, :pts, :dts, :is_aligned, :discontinuity, :length]

  require Logger

  @impl true
  def is_unmarshable?(_data, false) do
    true
  end

  def is_unmarshable?(<<1::24, _stream_id::8, _length::16, _optional::bitstring>>, true) do
    true
  end

  def is_unmarshable?(_data, _true) do
    false
  end

  @impl true
  def unmarshal(
        <<1::24, stream_id::8, packet_length::16, optional_fields::binary>>,
        true
      ) do
    with {:ok, optional, header_size, payload} <-
           parse_optional_header(optional_fields, has_header?(stream_id)) do
      {:ok,
       %__MODULE__{
         data: payload,
         stream_id: stream_id,
         dts: Map.get(optional, :dts),
         pts: Map.get(optional, :pts),
         length: if(packet_length > 0, do: packet_length - header_size, else: 0),
         is_aligned: Map.get(optional, :is_aligned, false)
       }}
    end
  end

  def unmarshal(_, true), do: {:error, :invalid_packet}
  def unmarshal(data, false), do: {:ok, %__MODULE__{data: data}}

  @padding_stream_id 0xBE
  @private_1_stream_id 0xBD
  @private_2_stream_id 0xBF

  defp has_header?(id)
       when id in [@padding_stream_id, @private_1_stream_id, @private_2_stream_id],
       do: false

  defp has_header?(_other), do: true

  defp parse_optional_header(data, false), do: {:ok, %{}, 0, data}

  defp parse_optional_header(
         x =
           <<
             0b10::2,
             _scrambling_control::2,
             _priority::1,
             data_alignment_indicator::1,
             _copyright::1,
             _original_or_copy::1,
             pts_dts_indicator::2,
             _escr_flag::1,
             _es_rate_flag::1,
             _dsm_trick_mode_flag::1,
             _additional_copy_info_flag::1,
             _crc_flag::1,
             _extension_flag::1,
             pes_header_length::8,
             optional_fields::binary-size(pes_header_length),
             rest::binary
           >>,
         true
       ) do
    pts_dts_indicator = parse_pts_dts_indicator(pts_dts_indicator)
    header_size = byte_size(x) - byte_size(rest)

    with {:ok, optionals_map, _rest} <- parse_pts_dts_field(optional_fields, pts_dts_indicator),
         {:ok, optionals_map} =
           parse_data_alignment_indicator(data_alignment_indicator, optionals_map) do
      {:ok, optionals_map, header_size, rest}
    end
  end

  defp parse_optional_header(_data, _has_header) do
    {:error, :invalid_optional_field}
  end

  defp parse_data_alignment_indicator(alignment_indicator, optionals_map) do
    alignment_indicator_flag =
      case alignment_indicator do
        0b0 -> false
        0b1 -> true
      end

    optionals_map =
      Map.put(
        optionals_map,
        :is_aligned,
        alignment_indicator_flag
      )

    {:ok, optionals_map}
  end

  defp parse_pts_dts_indicator(0b11), do: :pts_and_dts
  defp parse_pts_dts_indicator(0b01), do: :forbidden
  defp parse_pts_dts_indicator(0b10), do: :only_pts
  defp parse_pts_dts_indicator(0b00), do: :none

  # http://dvd.sourceforge.net/dvdinfo/pes-hdr.html
  # https://en.wikipedia.org/wiki/Presentation_timestamp
  defp parse_pts_dts_field(
         <<0b0010::4, chunk_one::bitstring-3, 0b1::1, chunk_two::bitstring-15, 0b1::1,
           chunk_three::bitstring-15, 0b1::1, rest::bitstring>>,
         :only_pts
       ) do
    pts = parse_pts_or_dts_chunks(chunk_one, chunk_two, chunk_three)
    {:ok, %{pts: pts, dts: pts}, rest}
  end

  defp parse_pts_dts_field(
         <<
           0b0011::4,
           pts_chunk_one::bitstring-3,
           0b1::1,
           pts_chunk_two::bitstring-15,
           0b1::1,
           pts_chunk_three::bitstring-15,
           0b1::1,
           0b0001::4,
           dts_chunk_one::bitstring-3,
           0b1::1,
           dts_chunk_two::bitstring-15,
           0b1::1,
           dts_chunk_three::bitstring-15,
           0b1::1,
           rest::bitstring
         >>,
         :pts_and_dts
       ) do
    pts = parse_pts_or_dts_chunks(pts_chunk_one, pts_chunk_two, pts_chunk_three)
    dts = parse_pts_or_dts_chunks(dts_chunk_one, dts_chunk_two, dts_chunk_three)
    {:ok, %{pts: pts, dts: dts}, rest}
  end

  defp parse_pts_dts_field(data, _indicator) do
    {:ok, %{}, data}
  end

  defp parse_pts_or_dts_chunks(chunk_one, chunk_two, chunk_three) do
    # PTS is a 33bit thing. If we add 7 it becomes a binary which can be
    # interpreted as a binary and hence an integer.
    # PTS and DTS originate from a 90kHz clock.
    <<ts::40>> = <<0b0::7, chunk_one::bitstring, chunk_two::bitstring, chunk_three::bitstring>>
    div(ts * 1_000_000_000, @ts_clock_hz)
  end
end
