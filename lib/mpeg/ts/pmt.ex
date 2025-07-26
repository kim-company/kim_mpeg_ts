defmodule MPEG.TS.PMT do
  @behaviour MPEG.TS.Unmarshaler

  alias MPEG.TS.PSI

  @moduledoc """
  Program Map Table.
  """

  @type stream_type_id_t :: 0..255
  @type stream_id_t :: 0..8191

  @type stream_t :: %{
          stream_type: atom,
          stream_type_id: stream_type_id_t
        }

  @type streams_t :: %{
          required(stream_id_t) => stream_t
        }

  defstruct [:pcr_pid, program_info: [], streams: %{}]

  @type t :: %__MODULE__{
          streams: streams_t(),
          program_info: list(),
          pcr_pid: 0..8191
        }

  @impl true
  def is_unmarshable?(data, is_start_unit = true) do
    case PSI.unmarshal_header(data, is_start_unit) do
      {:ok, {%{table_id: 0x02}, _rest}} -> true
      _ -> false
    end
  end

  def is_unmarshable?(_data, false), do: false

  @impl true
  def unmarshal(data, is_start_unit) do
    with {:ok, %PSI{table: table}} <- PSI.unmarshal(data, is_start_unit),
         {:ok, table} <- unmarshal_table(table) do
      {:ok, table}
    end
  end

  @spec unmarshal_table(binary()) :: {:ok, t()} | {:error, :invalid_data}
  def unmarshal_table(<<
        _reserved::3,
        pcr_pid::13,
        _reserved2::4,
        _::2,
        program_info_length::10,
        rest::binary
      >>) do
    with {:ok, {program_info, rest}} <- parse_program_info(program_info_length, rest),
         {:ok, streams} <- parse_streams(rest) do
      result = %__MODULE__{
        program_info: program_info,
        streams: streams,
        pcr_pid: pcr_pid
      }

      {:ok, result}
    end
  end

  defp parse_program_info(0, date), do: {:ok, {[], date}}

  defp parse_program_info(program_info_length, data) do
    # TODO: implement parsing
    <<_program_descriptors::binary-size(program_info_length), rest::binary>> = data
    {:ok, {[], rest}}
  end

  defp parse_streams(data, acc \\ %{})
  defp parse_streams(<<>>, acc), do: {:ok, acc}

  # TODO handle es_info (Page 54, Rec. ITU-T H.222.0 (03/2017))
  defp parse_streams(
         <<
           stream_type_id::8,
           _reserved::3,
           elementary_pid::13,
           _reserved1::4,
           program_info_length::12,
           _program_info::binary-size(program_info_length),
           rest::binary
         >>,
         acc
       ) do
    stream = %{
      stream_type_id: stream_type_id,
      stream_type: parse_stream_type(stream_type_id)
    }

    result = Map.put(acc, elementary_pid, stream)
    parse_streams(rest, result)
  end

  defp parse_streams(_, _) do
    {:error, :invalid_data}
  end

  @stream_id_to_atom %{
    0x00 => :RESERVED,
    0x01 => :MPEG1_VIDEO,
    0x02 => :MPEG2_VIDEO,
    0x03 => :MPEG1_AUDIO,
    0x04 => :MPEG2_AUDIO,
    0x05 => :MPEG2_PRIVATE_SECTIONS,
    0x06 => :MPEG2_PES_PRIVATE_DATA,
    0x07 => :MHEG,
    0x08 => :MPEG2_DSM_CC,
    0x09 => :H222_1,
    0x0A => :ISO_13818_6_TYPE_A,
    0x0B => :ISO_13818_6_TYPE_B,
    0x0C => :ISO_13818_6_TYPE_C,
    0x0D => :ISO_13818_6_TYPE_D,
    0x0E => :MPEG2_AUX,
    0x0F => :AAC,
    0x10 => :MPEG4_VISUAL,
    0x11 => :MPEG4_AUDIO,
    0x12 => :ISO_14496_1_IN_PES,
    0x13 => :ISO_14496_1_IN_SECTIONS,
    0x14 => :ISO_13818_6_DOWNLOAD,
    0x15 => :METADATA_IN_PES,
    0x16 => :METADATA_IN_SECTIONS,
    0x17 => :METADATA_IN_DATA_CAROUSEL,
    0x18 => :METADATA_IN_OBJECT_CAROUSEL,
    0x19 => :METADATA_IN_SYNC_DOWNLOAD,
    0x1A => :IPMP,
    0x1B => :H264,
    0x1C => :ISO_14496_10_TEXT,
    0x1D => :AUX_VIDEO,
    0x1E => :SVC,
    0x1F => :MPEG4_SVC,
    0x20 => :MPEG4_MVC,
    0x21 => :JPEG_2000_VIDEO,
    0x22 => :S3D_MPEG2_VIDEO,
    0x23 => :S3D_AVC_VIDEO,
    0x24 => :HEVC,
    0x25 => :HEVC_TEMPORAL_VIDEO,
    0x26 => :MVCD,
    0x27 => :HEVC_TEMPORAL_SCALABLE,
    0x28 => :HEVC_STEPWISE_TEMPORAL_SCALABLE,
    0x29 => :HEVC_LAYERED_TEMPORAL_SCALABLE,
    0x2A => :HEVC_LAYERED_TEMPORAL_SCALABLE_MVC,
    0x2B => :VVC,
    0x2C => :VVC_TEMPORAL_SCALABLE,
    0x2D => :VVC_TEMPORAL_SCALABLE_SUB_BITSTREAM,
    0x80 => :BLURAY_PCM_AUDIO,
    0x81 => :AC3_AUDIO,
    0x82 => :DTS_AUDIO,
    0x83 => :TRUEHD_AUDIO,
    0x84 => :EAC3_AUDIO,
    0x85 => :HDMV_DTS_AUDIO,
    0x86 => :DTS_HD_HRA_AUDIO,
    0x87 => :DTS_HD_MA_AUDIO,
    0x8A => :DTS_UHD_AUDIO,
    0x90 => :PGS_SUBTITLE,
    0x91 => :IGS_SUBTITLE,
    0x92 => :HDMV_TEXT_SUBTITLE,
    0x42 => :DVB_SUBTITLE,
    0x59 => :DVB_SUBTITLE_HD,
    0x73 => :ATSC_DVD_CONTROL,
    0x77 => :ATSC_DOLBY_E,
    0x7F => :IPMP_CONTROL,
    0xC0 => :SCTE_35_SPLICE,
    0xC1 => :SCTE_35_RESERVED,
    0xC2 => :SCTE_35_RESERVED
  }

  @atom_to_stream_id @stream_id_to_atom
                     |> Enum.map(fn {k, v} -> {v, k} end)
                     |> Map.new()

  def parse_stream_type(val) when val >= 0xBC and val <= 0xEF, do: {:USER_PRIVATE, val}

  def parse_stream_type(val) do
    case Map.get(@stream_id_to_atom, val) do
      nil -> :undefined
      other -> other
    end
  end

  @spec encode_stream_type(atom()) :: stream_id_t()
  def encode_stream_type(val), do: Map.fetch!(@atom_to_stream_id, val)

  @doc """
  Categorizes a stream type as :video, :audio, or :other.

  ## Examples

      iex> get_stream_category(:H264)
      :video

      iex> get_stream_category(:AAC)
      :audio

      iex> get_stream_category(:DVB_SUBTITLE)
      :other
  """
  def get_stream_category(stream_type) do
    case stream_type do
      # Video stream types
      :MPEG1_VIDEO -> :video
      :MPEG2_VIDEO -> :video
      :MPEG4_VISUAL -> :video
      :H264 -> :video
      :AUX_VIDEO -> :video
      :SVC -> :video
      :MPEG4_SVC -> :video
      :MPEG4_MVC -> :video
      :JPEG_2000_VIDEO -> :video
      :S3D_MPEG2_VIDEO -> :video
      :S3D_AVC_VIDEO -> :video
      :HEVC -> :video
      :HEVC_TEMPORAL_VIDEO -> :video
      :MVCD -> :video
      :HEVC_TEMPORAL_SCALABLE -> :video
      :HEVC_STEPWISE_TEMPORAL_SCALABLE -> :video
      :HEVC_LAYERED_TEMPORAL_SCALABLE -> :video
      :HEVC_LAYERED_TEMPORAL_SCALABLE_MVC -> :video
      :VVC -> :video
      :VVC_TEMPORAL_SCALABLE -> :video
      :VVC_TEMPORAL_SCALABLE_SUB_BITSTREAM -> :video
      # Audio stream types
      :MPEG1_AUDIO -> :audio
      :MPEG2_AUDIO -> :audio
      :AAC -> :audio
      :MPEG4_AUDIO -> :audio
      :BLURAY_PCM_AUDIO -> :audio
      :AC3_AUDIO -> :audio
      :DTS_AUDIO -> :audio
      :TRUEHD_AUDIO -> :audio
      :EAC3_AUDIO -> :audio
      :HDMV_DTS_AUDIO -> :audio
      :DTS_HD_HRA_AUDIO -> :audio
      :DTS_HD_MA_AUDIO -> :audio
      :DTS_UHD_AUDIO -> :audio
      :ATSC_DOLBY_E -> :audio
      # All other types (subtitles, private data, etc.)
      _ -> :other
    end
  end

  @doc """
  Categorizes a stream based on its stream_id (as an integer value) as :video, :audio, or :other.

  ## Examples

      iex> get_stream_category_by_id(0x1B)
      :video

      iex> get_stream_category_by_id(0x0F)
      :audio

      iex> get_stream_category_by_id(0x42)
      :other
  """
  def get_stream_category_by_id(stream_id) when is_integer(stream_id) do
    stream_id
    |> parse_stream_type()
    |> get_stream_category()
  end

  @doc """
  Determines if a given stream type is a video stream.

  ## Examples

      iex> is_video_stream?(:H264)
      true

      iex> is_video_stream?(:AAC)
      false
  """
  def is_video_stream?(stream_type) do
    get_stream_category(stream_type) == :video
  end

  @doc """
  Determines if a given stream type is an audio stream.

  ## Examples

      iex> is_audio_stream?(:AAC)
      true

      iex> is_audio_stream?(:H264)
      false
  """
  def is_audio_stream?(stream_type) do
    get_stream_category(stream_type) == :audio
  end

  defimpl MPEG.TS.Marshaler do
    def marshal(pmt) do
      streams =
        Enum.map_join(pmt.streams, fn {pid, stream} ->
          <<stream.stream_type_id::8, 0b111::3, pid::13, 0b1111::4, 0::12>>
        end)

      <<0b111::3, pmt.pcr_pid::13, 0b1111::4, 0::12>> <> streams
    end
  end
end
