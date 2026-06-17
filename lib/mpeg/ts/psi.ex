defmodule MPEG.TS.PSI do
  @behaviour MPEG.TS.Unmarshaler

  alias MPEG.TS.{PAT, PMT, SCTE35}
  require Logger

  @moduledoc """
  Program Specific Information payload. Supported tables are PMT and PAT.
  """

  @type header_t :: %{
          table_id: 0..255,
          section_syntax_indicator: boolean,
          section_length: 0..4095,
          transport_stream_id: 0..65_535 | nil,
          version_number: 0..31 | nil,
          current_next_indicator: boolean | nil,
          section_number: 0..255 | nil,
          last_section_number: 0..255 | nil
        }
  @type t :: %__MODULE__{
          header: header_t(),
          table_type: atom(),
          table: struct() | bitstring(),
          crc: binary()
        }
  defstruct [:header, :table_type, :table, :crc]

  @crc_length 4
  @remaining_header_length 5

  @impl true
  def unmarshal(data, is_start_unit) do
    with {:ok, {header, data}} <- unmarshal_header(data, is_start_unit) do
      header_overhead = if header.section_syntax_indicator, do: @remaining_header_length, else: 0
      content_length = header.section_length - @crc_length - header_overhead

      with <<raw_data::binary-size(^content_length), crc::@crc_length-binary, _::binary>> <- data,
           table_type = table_id_to_type(header.table_id) do
        case unmarshal_table(raw_data, table_type, is_start_unit) do
          {:ok, table} ->
            {:ok,
             %__MODULE__{
               header: header,
               table_type: table_type,
               table: table,
               crc: crc
             }}

          {:error, reason} ->
            # It means we were not able to parse PSI contents. To be as resilient as possible, we prefer
            # going on.
            Logger.warning("Unable to unmarshal PSI: #{inspect(reason)} -- forwarding RAW table")

            {:ok,
             %__MODULE__{
               header: header,
               table_type: table_type,
               table: raw_data,
               crc: crc
             }}
        end
      else
        _ ->
          {:error, :invalid_data}
      end
    end
  end

  def unmarshal_header(<<0::8, data::bitstring>>, true), do: unmarshal_header(data)

  def unmarshal_header(data, true) do
    # For short form sections (like SCTE-35), there may be no pointer field
    case unmarshal_header(data) do
      {:ok, {%{section_syntax_indicator: false} = header, rest}} -> {:ok, {header, rest}}
      _ -> {:error, :invalid_header}
    end
  end

  def unmarshal_header(data, false), do: unmarshal_header(data)

  def unmarshal_header(<<
        table_id::8,
        section_syntax_indicator::1,
        _private_bit::1,
        _sap_type::2,
        section_length::12,
        rest::binary
      >>)
      when section_length <= 4093 do
    case section_syntax_indicator do
      1 -> unmarshal_long_header(table_id, section_length, rest)
      0 -> unmarshal_short_header(table_id, section_length, rest)
    end
  end

  def unmarshal_header(_), do: {:error, :invalid_header}

  defp unmarshal_table(data, :pat, is_unit_start) do
    PAT.unmarshal(data, is_unit_start)
  end

  defp unmarshal_table(data, :pmt, is_unit_start) do
    PMT.unmarshal(data, is_unit_start)
  end

  defp unmarshal_table(data, :scte35, is_unit_start) do
    SCTE35.unmarshal(data, is_unit_start)
  rescue
    _e ->
      {:error, :scte35_unmarshal_error}
  end

  defp unmarshal_table(data, _table_type, _is_unit_start), do: {:ok, data}

  defp unmarshal_long_header(table_id, section_length, <<
         transport_stream_id::16,
         _r2::2,
         version_number::5,
         current_next_indicator::1,
         section_number::8,
         last_section_number::8,
         rest::binary
       >>) do
    header = %{
      table_id: table_id,
      section_syntax_indicator: true,
      section_length: section_length,
      transport_stream_id: transport_stream_id,
      version_number: version_number,
      current_next_indicator: current_next_indicator == 1,
      section_number: section_number,
      last_section_number: last_section_number
    }

    {:ok, {header, rest}}
  end

  defp unmarshal_short_header(table_id, section_length, rest) do
    header = %{
      table_id: table_id,
      section_syntax_indicator: false,
      section_length: section_length,
      transport_stream_id: nil,
      version_number: nil,
      current_next_indicator: nil,
      section_number: nil,
      last_section_number: nil
    }

    {:ok, {header, rest}}
  end

  @doc """
  Maps a table_id to its corresponding table type atom based on ISO/IEC 13818-1.

  ## Standard Table IDs (ISO/IEC 13818-1)

  - `0x00` - Program Association Table (PAT)
  - `0x01` - Conditional Access Table (CAT)
  - `0x02` - Program Map Table (PMT)
  - `0x03` - Transport Stream Description Table
  - `0x04` - ISO/IEC 14496 scene description section
  - `0x05` - ISO/IEC 14496 object description section
  - `0x06` - Metadata section
  - `0x07` - ISO/IEC 13818-11 IPMP control information (DRM)
  - `0x08-0x39` - Reserved
  - `0x3A-0x3F` - ISO/IEC 13818-6 DSM CC sections
  - `0x40-0x7F` - Used by DVB
  - `0x80-0x8F` - DVB-CSA and DigiCipher II/ATSC CA message sections
  - `0x90-0xBF` - May be assigned as needed to other data tables
  - `0xC0-0xFE` - Used by DigiCipher II/ATSC/SCTE (includes SCTE-35 at 0xFC)
  - `0xFF` - Forbidden (used for null padding)

  ## Examples

      iex> table_id_to_type(0x00)
      :pat

      iex> table_id_to_type(0x02)
      :pmt

      iex> table_id_to_type(0xFC)
      :scte35

      iex> table_id_to_type(0xFF)
      :forbidden
  """
  @spec table_id_to_type(0..255) :: atom()
  def table_id_to_type(0x00), do: :pat
  def table_id_to_type(0x01), do: :cat
  def table_id_to_type(0x02), do: :pmt
  def table_id_to_type(0x03), do: :tsdt
  def table_id_to_type(0x04), do: :iso14496_scene_description
  def table_id_to_type(0x05), do: :iso14496_object_description
  def table_id_to_type(0x06), do: :metadata
  def table_id_to_type(0x07), do: :ipmp_control_information
  def table_id_to_type(id) when id >= 0x08 and id <= 0x39, do: :reserved
  def table_id_to_type(0x3A), do: :dsm_cc_multiprotocol_encapsulated
  def table_id_to_type(0x3B), do: :dsm_cc_un_messages
  def table_id_to_type(0x3C), do: :dsm_cc_download_data_messages
  def table_id_to_type(0x3D), do: :dsm_cc_stream_descriptor_list
  def table_id_to_type(0x3E), do: :dsm_cc_privately_defined
  def table_id_to_type(0x3F), do: :dsm_cc_addressable
  def table_id_to_type(id) when id >= 0x40 and id <= 0x7F, do: :dvb
  def table_id_to_type(id) when id >= 0x80 and id <= 0x8F, do: :ca_message_section
  def table_id_to_type(id) when id >= 0x90 and id <= 0xBF, do: :user_defined
  def table_id_to_type(0xFC), do: :scte35
  def table_id_to_type(id) when id >= 0xC0 and id <= 0xFE, do: :atsc_scte
  def table_id_to_type(0xFF), do: :forbidden

  defimpl MPEG.TS.Marshaler do
    import Bitwise

    @crc_length 4
    @remaining_header_length 5

    def marshal(%{header: header, table: table}) do
      table = MPEG.TS.Marshaler.marshal(table)

      section_length =
        if header.section_syntax_indicator,
          do: byte_size(table) + @remaining_header_length + @crc_length,
          else: byte_size(table) + @crc_length

      psi_header =
        <<header.table_id::8, bool_to_int(header.section_syntax_indicator)::1,
          _private_bit = 0::1, _reserved = 0b11::2, 0::2, section_length::10>>

      long_header =
        if header.section_syntax_indicator do
          <<header.transport_stream_id::16, 0b11::2, header.version_number::5,
            bool_to_int(header.current_next_indicator)::1, header.section_number::8,
            header.last_section_number::8>>
        else
          <<>>
        end

      payload = psi_header <> long_header <> table
      <<0, payload::binary, crc32(payload)::32>>
    end

    defp bool_to_int(true), do: 1
    defp bool_to_int(_), do: 0

    defp crc32(data) do
      data
      |> :binary.bin_to_list()
      |> Enum.reduce(0xFFFFFFFF, fn byte, crc ->
        crc = bxor(crc, byte <<< 24)

        Enum.reduce(0..7, crc, fn _i, crc ->
          if (crc &&& 0x80000000) == 0, do: crc <<< 1, else: bxor(crc <<< 1, 0x104C11DB7)
        end)
      end)
    end
  end
end
