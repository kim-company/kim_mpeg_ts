defmodule MPEG.TS.SCTE35 do
  @behaviour MPEG.TS.Unmarshaler

  @moduledoc """
  SCTE-35 Digital Program Insertion Cueing Message.

  Handles parsing of SCTE-35 splice information tables used for
  ad insertion and program signaling in MPEG-TS streams.
  """

  defmodule SpliceInsert do
    @behaviour MPEG.TS.Unmarshaler
    defstruct [
      :event_id,
      :cancel_indicator,
      :out_of_network_indicator,
      :program_splice_flag,
      :duration_flag,
      :splice_immediate_flag,
      :event_id_compliance_flag,
      :splice_time,
      :break_duration,
      :unique_program_id,
      :avail_num,
      :avails_expected
    ]

    @impl true
    def unmarshal(<<event_id::32, cancel_indicator::1, _reserved::7, rest::binary>>, _start_unit) do
      cmd = %__MODULE__{
        event_id: event_id,
        cancel_indicator: cancel_indicator
      }

      cmd = parse_event_cancel_section(cmd, rest)
      {:ok, cmd}
    end

    def unmarshal(_, _), do: {:error, :invalid_splice_insert}

    defp parse_event_cancel_section(
           cmd = %{cancel_indicator: 0},
           <<
             out_of_network_indicator::1,
             1::1,
             break_duration_flag::1,
             splice_immediate_flag::1,
             event_id_compliance_flag::1,
             0b111::3,
             rest::binary
           >>
         ) do
      {splice_time, rest} = parse_splice_time(splice_immediate_flag, rest)
      {break_duration, rest} = parse_break_duration(break_duration_flag, rest)

      <<unique_program_id::16, avail_num::8, avails_expected::8>> = rest

      cmd
      |> put_in([Access.key!(:out_of_network_indicator)], out_of_network_indicator)
      |> put_in([Access.key!(:program_splice_flag)], 1)
      |> put_in([Access.key!(:duration_flag)], break_duration_flag)
      |> put_in([Access.key!(:splice_immediate_flag)], splice_immediate_flag)
      |> put_in([Access.key!(:event_id_compliance_flag)], event_id_compliance_flag)
      |> put_in([Access.key!(:splice_time)], splice_time)
      |> put_in([Access.key!(:break_duration)], break_duration)
      |> put_in([Access.key!(:unique_program_id)], unique_program_id)
      |> put_in([Access.key!(:avail_num)], avail_num)
      |> put_in([Access.key!(:avails_expected)], avails_expected)
    end

    defp parse_event_cancel_section(cmd, _), do: cmd

    defp parse_splice_time(0, <<1::1, 0b111111::6, pts_time::33, rest::binary>>),
      do: {%{pts: MPEG.TS.convert_ts_to_ns(pts_time)}, rest}

    defp parse_splice_time(0, <<0::1, 0b1111111::7, rest::binary>>), do: {nil, rest}
    defp parse_splice_time(1, rest), do: {nil, rest}

    defp parse_break_duration(
           1,
           <<auto_return::1, 0b111111::6, duration::33, rest::binary>>
         ) do
      {%{auto_return: auto_return, duration: MPEG.TS.convert_ts_to_ns(duration)}, rest}
    end

    defp parse_break_duration(0, rest), do: {nil, rest}

    defimpl MPEG.TS.Marshaler do
      def marshal(cmd = %MPEG.TS.SCTE35.SpliceInsert{}) do
        header = <<cmd.event_id::32, cmd.cancel_indicator::1, 0b1111111::7>>

        if cmd.cancel_indicator == 0 do
          info =
            <<cmd.out_of_network_indicator::1, cmd.program_splice_flag::1, cmd.duration_flag::1,
              cmd.splice_immediate_flag::1, cmd.event_id_compliance_flag::1, 0b111::3>>

          splice_time =
            if cmd.program_splice_flag == 1 and cmd.splice_immediate_flag == 0,
              do: <<1::1, 0b111111::6, MPEG.TS.convert_ns_to_ts(cmd.splice_time.pts)::33>>,
              else: <<>>

          break_duration =
            if cmd.duration_flag == 1,
              do:
                <<cmd.break_duration.auto_return::1, 0b111111::6,
                  MPEG.TS.convert_ns_to_ts(cmd.break_duration.duration)::33>>,
              else: <<>>

          IO.iodata_to_binary([
            header,
            info,
            splice_time,
            break_duration,
            <<cmd.unique_program_id::16, cmd.avail_num::8, cmd.avails_expected::8>>
          ])
        else
          header
        end
      end
    end
  end

  defmodule SpliceNull do
    @behaviour MPEG.TS.Unmarshaler

    defstruct []

    @impl true
    def unmarshal(<<>>, _start_unit), do: {:ok, %__MODULE__{}}
    def unmarshal(_, _start_unit), do: {:error, :invalid_splice_null}

    defimpl MPEG.TS.Marshaler do
      def marshal(%MPEG.TS.SCTE35.SpliceNull{}), do: <<>>
    end
  end

  @type splice_command_type_t ::
          :splice_null
          | :splice_schedule
          | :splice_insert
          | :time_signal
          | :bandwidth_reservation
          | :private_command

  defstruct [
    # SCTE-35 header fields
    :protocol_version,
    :encrypted_packet,
    :encryption_algorithm,
    :pts_adjustment,
    :cw_index,
    :tier,
    :splice_command_type,
    :splice_command,
    :splice_descriptors,
    :e_crc32
  ]

  @type t :: %__MODULE__{
          protocol_version: 0..255,
          encrypted_packet: pos_integer(),
          encryption_algorithm: 0..63,
          pts_adjustment: integer(),
          cw_index: 0..255,
          tier: 0..0xFFF,
          splice_command_type: splice_command_type_t(),
          splice_command: struct(),
          splice_descriptors: list(),
          e_crc32: binary()
        }

  @impl true
  def unmarshal(data, true) do
    unmarshal_table(data)
  end

  def unmarshal(_data, _is_unit_start) do
    {:error, :invalid_data}
  end

  @spec unmarshal_table(binary()) :: {:ok, t()} | {:error, :invalid_data}
  def unmarshal_table(<<
        protocol_version::8,
        encrypted_packet_flag::1,
        encryption_algorithm::6,
        pts_adjustment::33,
        cw_index::8,
        tier::12,
        splice_command_length::12,
        splice_command_type::8,
        splice_info_section::binary-size(splice_command_length),
        descriptor_loop_length::16,
        _descriptor_loop::binary-size(descriptor_loop_length),
        rest::binary
      >>) do
    with {:ok, command_type} <- parse_splice_command_type(splice_command_type),
         {:ok, command} <- parse_splice_command(command_type, splice_info_section) do
      e_crc32 =
        if encrypted_packet_flag == 1 do
          <<e_crc32::4-binary>> = rest
          e_crc32
        else
          <<>> = rest
        end

      {:ok,
       %__MODULE__{
         protocol_version: protocol_version,
         encrypted_packet: encrypted_packet_flag,
         encryption_algorithm: encryption_algorithm,
         pts_adjustment: pts_adjustment,
         cw_index: cw_index,
         tier: tier,
         splice_command_type: command_type,
         splice_command: command,
         # TODO: we're not parsing the descriptors!
         splice_descriptors: [],
         e_crc32: e_crc32
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def unmarshal_table(_), do: {:error, :invalid_data}

  @splice_type_to_id %{
    0x00 => :splice_null,
    0x04 => :splice_schedule,
    0x05 => :splice_insert,
    0x06 => :time_signal,
    0x07 => :bandwidth_reservation
  }

  defp parse_splice_command_type(type) do
    if id = @splice_type_to_id[type] do
      {:ok, id}
    else
      {:error, :unknown_splice_type}
    end
  end

  defp parse_splice_command(:splice_null, data), do: SpliceNull.unmarshal(data, true)
  defp parse_splice_command(:splice_insert, data), do: SpliceInsert.unmarshal(data, true)
  defp parse_splice_command(_type, _data), do: {:error, :splice_command_not_implemented}

  defimpl MPEG.TS.Marshaler do
    @splice_id_to_type %{
      :splice_null => 0x00,
      :splice_schedule => 0x04,
      :splice_insert => 0x05,
      :time_signal => 0x06,
      :bandwidth_reservation => 0x07
    }
    def marshal(scte = %MPEG.TS.SCTE35{splice_descriptors: []}) do
      splice_command = MPEG.TS.Marshaler.marshal(scte.splice_command)
      splice_command_type = @splice_id_to_type[scte.splice_command_type]
      splice_command_size = IO.iodata_length(splice_command)

      descriptor_loop_length = 0

      <<scte.protocol_version::8, scte.encrypted_packet::1, scte.encryption_algorithm::6,
        scte.pts_adjustment::33, scte.cw_index::8, scte.tier::12, splice_command_size::12,
        splice_command_type::8>> <>
        splice_command <> <<descriptor_loop_length::16>> <> scte.e_crc32
    end
  end
end
