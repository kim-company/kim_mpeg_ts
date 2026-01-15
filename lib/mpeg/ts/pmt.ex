defmodule MPEG.TS.PMT do
  @behaviour MPEG.TS.Unmarshaler

  @moduledoc """
  Program Map Table.
  """

  @type stream_type_id_t :: 0..255
  @type stream_id_t :: 0..8191

  @type stream_t :: %{
          stream_type: atom,
          stream_type_id: stream_type_id_t,
          descriptors: list()
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
  def unmarshal(data, true) do
    unmarshal_table(data)
  end

  def unmarshal(_, _) do
    {:error, :invalid_data}
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
    <<program_descriptors::binary-size(program_info_length), rest::binary>> = data
    {:ok, {parse_descriptors(program_descriptors, []), rest}}
  end

  defp parse_descriptors(<<>>, acc), do: Enum.reverse(acc)

  defp parse_descriptors(
         <<tag::8, length::8, data::binary-size(length), rest::binary>>,
         acc
       ) do
    descriptor = %{tag: tag, data: data}
    parse_descriptors(rest, [descriptor | acc])
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
           program_info::binary-size(program_info_length),
           rest::binary
         >>,
         acc
       ) do
    stream = %{
      stream_type_id: stream_type_id,
      stream_type: parse_stream_type(stream_type_id),
      descriptors: parse_descriptors(program_info, [])
    }

    result = Map.put(acc, elementary_pid, stream)
    parse_streams(rest, result)
  end

  defp parse_streams(_, _) do
    {:error, :invalid_data}
  end

  @stream_id_to_atom %{
    0x00 => :RESERVED,
    # ISO/IEC 11172-2
    0x01 => :MPEG1_VIDEO,
    # ITU-T H.262 / ISO/IEC 13818-2
    0x02 => :MPEG2_VIDEO,
    # ISO/IEC 11172-3
    0x03 => :MPEG1_AUDIO,
    # ISO/IEC 13818-3
    0x04 => :MPEG2_AUDIO,
    # private_sections
    0x05 => :PRIVATE_SECTIONS,
    # used for DVB subtitles via descriptor 0x59
    0x06 => :PES_PRIVATE_DATA,
    # ISO/IEC 13522
    0x07 => :MHEG,
    # ISO/IEC 13818-1 DSM-CC
    0x08 => :DSM_CC,
    # H.222.0 / 11172-1 aux
    0x09 => :H222_1_AUX,
    # DSM-CC multiprotocol encapsulation
    0x0A => :ISO_13818_6_TYPE_A,
    # DSM-CC U-N messages
    0x0B => :ISO_13818_6_TYPE_B,
    # DSM-CC stream descriptors
    0x0C => :ISO_13818_6_TYPE_C,
    # DSM-CC sections
    0x0D => :ISO_13818_6_TYPE_D,
    # ISO/IEC 13818-1 ancillary
    0x0E => :ANCILLARY_DATA,
    # ISO/IEC 13818-7 ADTS AAC
    0x0F => :AAC_ADTS,
    # ISO/IEC 14496-2
    0x10 => :MPEG4_VISUAL,
    # ISO/IEC 14496-3 LATM/LOAS
    0x11 => :MPEG4_AUDIO_LATM,
    # MPEG-4 SL in PES
    0x12 => :ISO_14496_1_SL_IN_PES,
    # MPEG-4 SL in sections / FlexMux
    0x13 => :ISO_14496_1_SL_IN_SECTIONS,
    # DSM-CC sync download
    0x14 => :ISO_13818_6_DOWNLOAD,
    0x15 => :METADATA_IN_PES,
    0x16 => :METADATA_IN_SECTIONS,
    0x17 => :METADATA_IN_DATA_CAROUSEL,
    0x18 => :METADATA_IN_OBJECT_CAROUSEL,
    0x19 => :METADATA_IN_SYNC_DOWNLOAD,
    # ISO/IEC 13818-11
    0x1A => :IPMP,
    # ITU-T H.264 / ISO/IEC 14496-10
    0x1B => :H264_AVC,
    # ISO/IEC 14496-3 raw audio
    0x1C => :MPEG4_RAW_AUDIO,
    # ISO/IEC 14496-17 text
    0x1D => :MPEG4_TEXT,
    # ISO/IEC 23002-3 auxiliary video
    0x1E => :MPEG4_AUX_VIDEO,
    # AVC SVC sub-bitstream
    0x1F => :SVC_SUB_BITSTREAM,
    # AVC MVC sub-bitstream
    0x20 => :MVC_SUB_BITSTREAM,
    # ITU-T T.800 / ISO/IEC 15444
    0x21 => :JPEG2000_VIDEO,
    0x22 => :RESERVED,
    0x23 => :RESERVED,
    # ITU-T H.265 / ISO/IEC 23008-2 (HEVC) main stream
    0x24 => :HEVC,
    # HEVC temporal video subset
    0x25 => :HEVC_TEMPORAL_VIDEO_SUBSET,
    # generic metadata (per ISO table)
    0x26 => :METADATA,
    # metadata STD
    0x27 => :METADATA_STD,
    # HEVC sub-partition (hierarchy/operation points)
    0x28 => :HEVC_SUB_PARTITION,
    # HEVC timing/HRD signaling
    0x29 => :HEVC_TIMING_HRD,
    # HEVC base sub-partition (per Amd.2 notes)
    0x2A => :HEVC_SUB_PARTITION_BASE,
    # HEVC enhancement/temporal sub-partition
    0x2B => :HEVC_SUB_PARTITION_ENH,

    # --- Private / ecosystem-specific assignments ---

    # Blu-ray (BDAV) commonly-used private stream_types:
    # Blu-ray PCM (note: 0x80 also used by DigiCipher II in cable)
    0x80 => :BD_PCM_AUDIO,
    # Dolby Digital (Blu-ray/ATSC)
    0x81 => :AC3_AUDIO,
    # DTS (Blu-ray)
    0x82 => :DTS_AUDIO,
    # Dolby TrueHD (Blu-ray)
    0x83 => :TRUEHD_AUDIO,
    # Dolby Digital Plus (Blu-ray)
    0x84 => :EAC3_AUDIO,
    # DTS-HD (Blu-ray)
    0x85 => :DTS_HD_AUDIO,
    # 0x86 has two competing uses in the wild:
    #   - Broadcast/cable: SCTE-35 splice info (standardized & used by FFmpeg)
    #   - Blu-ray: sometimes reported for DTS-HD MA/LRA variants
    # Prefer mapping to SCTE-35 for TS tooling; Blu-ray disambiguates via descriptors.
    # SCTE-35 cue messages
    0x86 => :SCTE_35_SPLICE,
    # E-AC-3 (ATSC usage)
    0x87 => :EAC3_AUDIO_ATSC,
    # 0x88–0x8F: privately defined; left unmapped
    # Blu-ray Presentation Graphic Stream (PGS)
    0x90 => :PGS_SUBTITLE,
    # 0x91 is not Blu-ray IGS; it's used by ATSC DSM-CC Network Resources in some lists
    0x91 => :ATSC_DSMCC_NETWORK_RESOURCES,

    # DigiCipher II / ATSC private (examples commonly seen)
    0xC0 => :DIGICIPHER_TEXT,
    0xC1 => :AC3_AES128_ENCRYPTED,
    0xC2 => :ATSC_DSMCC_SYNC_DATA,

    # --- Newer video codecs ---
    # H.266 / VVC in MPEG-TS
    0x33 => :VVC,
    # lightweight low-latency lossless quality video coding.
    0x32 => :JPEGXS
    # (Other 0xD1.. entries like Dirac/AVS are vendor/region-specific and left out unless you need them)
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

  @non_pes_stream_types [
    :RESERVED,
    :undefined,
    :PRIVATE_SECTIONS,
    :MHEG,
    :DSM_CC,
    :ISO_13818_6_TYPE_A,
    :ISO_13818_6_TYPE_B,
    :ISO_13818_6_TYPE_C,
    :ISO_13818_6_TYPE_D,
    :ISO_13818_6_DOWNLOAD,
    :ISO_14496_1_SL_IN_SECTIONS,
    :METADATA_IN_SECTIONS,
    :METADATA_IN_DATA_CAROUSEL,
    :METADATA_IN_OBJECT_CAROUSEL,
    :METADATA_IN_SYNC_DOWNLOAD,
    :SCTE_35_SPLICE,
    :SCTE_35_RESERVED,
    :IPMP
  ]

  @doc """
  Returns true for stream types that carry PES packets.
  """
  @spec pes_stream_type?(atom() | {atom(), stream_type_id_t()}) :: boolean()
  def pes_stream_type?({:USER_PRIVATE, _stream_type_id}), do: true

  def pes_stream_type?(stream_type) when stream_type in @non_pes_stream_types, do: false

  def pes_stream_type?(_stream_type), do: true

  @doc """
  Returns true for streams that carry PES packets, using descriptors when needed.
  """
  @spec pes_stream?(stream_t()) :: boolean()
  def pes_stream?(%{stream_type: stream_type} = stream) do
    case stream_type do
      :PES_PRIVATE_DATA ->
        # DVB subtitles/teletext still use PES (descriptor tags 0x59/0x56).
        true

      other ->
        pes_stream_type?(other) and not has_non_pes_descriptor?(stream)
    end
  end

  defp has_non_pes_descriptor?(%{descriptors: descriptors}) do
    Enum.any?(descriptors, fn
      # Metadata section (per ISO/IEC 13818-1 Table 2-45).
      %{tag: 0x2D} -> true
      _ -> false
    end)
  end

  @doc """
  Categorizes a stream type as :video, :audio, or :other.

  ## Examples

      iex> get_stream_category(:H264_AVC)
      :video

      iex> get_stream_category(:AAC_ADTS)
      :audio

      iex> get_stream_category(:DVB_SUBTITLE)
      :subtitles
  """
  def get_stream_category(stream_type) do
    case stream_type do
      # -------------------------
      # VIDEO
      # -------------------------
      t
      when t in [
             :MPEG1_VIDEO,
             :MPEG2_VIDEO,
             :MPEG4_VISUAL,
             :H264_AVC,
             :AUX_VIDEO,
             :MPEG4_AUX_VIDEO,
             :SVC,
             :SVC_SUB_BITSTREAM,
             :MPEG4_SVC,
             :MPEG4_MVC,
             :MVC_SUB_BITSTREAM,
             :JPEG_2000_VIDEO,
             :HEVC,
             :HEVC_TEMPORAL_VIDEO,
             :HEVC_TEMPORAL_SCALABLE,
             :HEVC_STEPWISE_TEMPORAL_SCALABLE,
             :HEVC_LAYERED_TEMPORAL_SCALABLE,
             :HEVC_LAYERED_TEMPORAL_SCALABLE_MVC,
             :HEVC_TEMPORAL_VIDEO_SUBSET,
             :HEVC_SUB_PARTITION,
             :HEVC_TIMING_HRD,
             :HEVC_SUB_PARTITION_BASE,
             :HEVC_SUB_PARTITION_ENH,
             :JPEGXS,
             :VVC,
             :VVC_TEMPORAL_SCALABLE,
             :VVC_TEMPORAL_SCALABLE_SUB_BITSTREAM
           ] ->
        :video

      # -------------------------
      # AUDIO
      # -------------------------
      t
      when t in [
             :MPEG1_AUDIO,
             :MPEG2_AUDIO,
             :AAC_ADTS,
             :MPEG4_AUDIO,
             :MPEG4_AUDIO_LATM,
             :BLURAY_PCM_AUDIO,
             :BD_PCM_AUDIO,
             :AC3_AUDIO,
             :EAC3_AUDIO,
             :EAC3_AUDIO_ATSC,
             :DTS_AUDIO,
             :DTS_HD_AUDIO,
             :DTS_HD_HRA_AUDIO,
             :DTS_HD_MA_AUDIO,
             :DTS_UHD_AUDIO,
             :TRUEHD_AUDIO,
             :ATSC_DOLBY_E
           ] ->
        :audio

      # -------------------------
      # SUBTITLES / GRAPHICS
      # (Note: DVB subtitles are signaled with stream_type 0x06 + descriptor 0x59.)
      # -------------------------
      t
      when t in [
             :PGS_SUBTITLE,
             :HDMV_TEXT_SUBTITLE,
             :DVB_SUBTITLE,
             :DVB_SUBTITLE_HD
           ] ->
        :subtitles

      # -------------------------
      # CUES / AD-MARKERS
      # -------------------------
      t
      when t in [
             :SCTE_35_SPLICE,
             :SCTE_35_RESERVED
           ] ->
        :cues

      # -------------------------
      # METADATA
      # -------------------------
      t
      when t in [
             :METADATA_IN_PES,
             :METADATA_IN_SECTIONS,
             :METADATA_IN_DATA_CAROUSEL,
             :METADATA_IN_OBJECT_CAROUSEL,
             :METADATA_IN_SYNC_DOWNLOAD,
             :METADATA,
             :METADATA_STD
           ] ->
        :metadata

      # -------------------------
      # IPMP / DRM
      # -------------------------
      :IPMP ->
        :ipmp

      # -------------------------
      # GENERAL DATA / SIGNALING
      # (PES private, sections, DSM-CC, MHEG, ancillary, downloads, etc.)
      # -------------------------
      t
      when t in [
             :PRIVATE_SECTIONS,
             :PES_PRIVATE_DATA,
             :MHEG,
             :DSM_CC,
             :ISO_13818_6_TYPE_A,
             :ISO_13818_6_TYPE_B,
             :ISO_13818_6_TYPE_C,
             :ISO_13818_6_TYPE_D,
             :ANCILLARY_DATA,
             :ISO_13818_6_DOWNLOAD,
             :ISO_14496_1_SL_IN_PES,
             :ISO_14496_1_SL_IN_SECTIONS,
             :ATSC_DSMCC_NETWORK_RESOURCES,
             :DIGICIPHER_TEXT,
             :AC3_AES128_ENCRYPTED,
             :ATSC_DSMCC_SYNC_DATA
           ] ->
        :data

      # Fallback
      _ ->
        :other
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

      iex> is_video_stream?(:H264_AVC)
      true

      iex> is_video_stream?(:AAC_ADTS)
      false
  """
  def is_video_stream?(stream_type) do
    get_stream_category(stream_type) == :video
  end

  @doc """
  Determines if a given stream type is an audio stream.

  ## Examples

      iex> is_audio_stream?(:AAC_ADTS)
      true

      iex> is_audio_stream?(:H264_AVC)
      false
  """
  def is_audio_stream?(stream_type) do
    get_stream_category(stream_type) == :audio
  end

  defimpl MPEG.TS.Marshaler do
    def marshal(pmt) do
      streams =
        Enum.map_join(pmt.streams, fn {pid, stream} ->
          descriptors =
            Enum.map_join(Map.get(stream, :descriptors, []), fn %{tag: tag, data: data} ->
              <<tag::8, byte_size(data)::8>> <> data
            end)

          <<stream.stream_type_id::8, 0b111::3, pid::13, 0b1111::4, byte_size(descriptors)::12>> <>
            descriptors
        end)

      descriptors =
        Enum.map_join(pmt.program_info, fn %{tag: tag, data: data} ->
          <<tag::8, byte_size(data)::8>> <> data
        end)

      <<0b111::3, pmt.pcr_pid || 0x1FFF::13, 0b1111::4, 0::2, byte_size(descriptors)::10>> <>
        descriptors <> streams
    end
  end
end
